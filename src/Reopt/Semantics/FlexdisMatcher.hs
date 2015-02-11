------------------------------------------------------------------------
-- |
-- Module           : Reopt.Semantics.FlexdisMatcher
-- Description      : Pattern matches against a Flexdis86 InstructionInstance.
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Simon Winwood <sjw@galois.com>
-- Stability        : provisional
--
-- This contains a function "execInstruction" that steps a single Flexdis86
-- instruction.
------------------------------------------------------------------------
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Reopt.Semantics.FlexdisMatcher
  ( execInstruction
  ) where

import           Control.Applicative ( (<$>) )
import           Data.List (stripPrefix)
import           Data.Type.Equality -- (testEquality, castWith, :~:(..) )
import           GHC.TypeLits (KnownNat)

import qualified Flexdis86 as F
import           Reopt.Semantics
import           Reopt.Semantics.Monad

import           Data.Parameterized.NatRepr

data SomeBV v where
  SomeBV :: SupportedBVWidth n => v (BVType n) -> SomeBV v

-- -- | Extracts the value, truncating as required
-- getBVValue :: (FullSemantics m) => NatRepr n -> F.Value -> m (Value m (BVType n))
-- getBVValue (sz :: NatRepr n) v =
--   case v of
--     F.ControlReg cr     -> mk (CReg cr)
--     F.DebugReg dr       -> mk (DReg dr)
--     F.MMXReg mmx        -> mk (MMXReg mmx)
--     F.XMMReg xmm        -> mk (XMMReg xmm)
--     F.SegmentValue s    -> mk (SegmentReg s)
--     F.FarPointer _      -> fail "FarPointer"
--     -- If an instruction can take a VoidMem, it needs to get it explicitly
--     F.VoidMem _ar       -> fail "VoidMem"
--     F.Mem8  ar          -> getBVAddress ar >>= mk . mkBVAddr n8 -- FIXME: what size here?
--     F.Mem16 ar          -> getBVAddress ar >>= mk . mkBVAddr n16
--     F.Mem32 ar          -> getBVAddress ar >>= mk . mkBVAddr n32
--     F.Mem64 ar          -> getBVAddress ar >>= mk . mkBVAddr n64
--     F.ByteReg  r
--       | Just r64 <- F.is_low_reg r  -> mk (reg_low n8 r64)
--       | Just r64 <- F.is_high_reg r -> mk (reg_high n8 r64)
--       | otherwise                   -> fail "unknown r8"
--     F.WordReg  r                    -> mk (reg_low n16 (F.reg16_reg r))
--     F.DWordReg r                    -> mk (reg_low n32 (F.reg32_reg r))
--     F.QWordReg r                    -> mk (GPReg r)
--     F.ByteImm  w                    -> return (bvLit sz $ fromIntegral w) -- FIXME: should we cast here?
--     F.WordImm  w                    -> return (bvLit sz $ fromIntegral w)
--     F.DWordImm w                    -> return (bvLit sz $ fromIntegral w)
--     F.QWordImm w                    -> return (bvLit sz $ fromIntegral w)
--     F.JumpOffset off                -> return (bvLit sz $ fromIntegral off)
--   where
--     -- FIXME: what happens with signs etc?
--     mk :: forall m n'. (FullSemantics m, SupportedBVWidth n') => MLocation m (BVType n') -> m (Value m (BVType n))
--     mk l = do when (widthVal (loc_width l) < widthVal sz) $ fail "Extending in getBVValue"
--               get (BVSlice l 0 (BVTypeRepr sz))

-- | Extracts the value, truncating as required
getSomeBVValue :: FullSemantics m => F.Value -> m (SomeBV (Value m))
getSomeBVValue v =
  case v of
    F.ControlReg cr     -> mk (CReg cr)
    F.DebugReg dr       -> mk (DReg dr)
    F.MMXReg mmx        -> mk (MMXReg mmx)
    F.XMMReg xmm        -> mk (XMMReg xmm)
    F.SegmentValue s    -> mk (SegmentReg s)
    F.FarPointer _      -> fail "FarPointer"
    -- If an instruction can take a VoidMem, it needs to get it explicitly
    F.VoidMem _ar       -> fail "VoidMem"
    F.Mem8  ar          -> getBVAddress ar >>= mk . mkBVAddr n8 -- FIXME: what size here?
    F.Mem16 ar          -> getBVAddress ar >>= mk . mkBVAddr n16
    F.Mem32 ar          -> getBVAddress ar >>= mk . mkBVAddr n32
    F.Mem64 ar          -> getBVAddress ar >>= mk . mkBVAddr n64
    F.ByteReg  r
      | Just r64 <- F.is_low_reg r  -> mk (reg_low8 r64)
      | Just r64 <- F.is_high_reg r -> mk (reg_high8 r64)
      | otherwise                   -> fail "unknown r8"
    F.WordReg  r                    -> mk (reg_low16 (F.reg16_reg r))
    F.DWordReg r                    -> mk (reg_low32 (F.reg32_reg r))
    F.QWordReg r                    -> mk (GPReg r)
    F.ByteImm  w                    -> return (SomeBV $ bvLit n8  w) -- FIXME: should we cast here?
    F.WordImm  w                    -> return (SomeBV $ bvLit n16 w)
    F.DWordImm w                    -> return (SomeBV $ bvLit n32 w)
    F.QWordImm w                    -> return (SomeBV $ bvLit n64 w)
    F.JumpOffset off                -> return (SomeBV $ bvLit n64 off)
  where
    -- FIXME: what happens with signs etc?
    mk :: forall m n'. (FullSemantics m, SupportedBVWidth n') => MLocation m (BVType n') -> m (SomeBV (Value m))
    mk l = SomeBV <$> get l

-- | Calculates the address corresponding to an AddrRef
getBVAddress :: FullSemantics m => F.AddrRef -> m (Value m (BVType 64))
getBVAddress ar =
  case ar of
    F.Addr_32      _seg _m_r32 _m_int_r32 _i32 -> fail "Addr_32"
    F.IP_Offset_32 _seg _i32                 -> fail "IP_Offset_32"
    F.Offset_32    _seg _w32                 -> fail "Offset_32"
    F.Offset_64    seg w64                 -> do check_seg_value seg
                                                 return (bvLit n64 w64)
    F.Addr_64      seg m_r64 m_int_r64 i32 -> do check_seg_value seg
                                                 base <- case m_r64 of
                                                           Nothing -> return v0_64
                                                           Just r  -> get (GPReg r)
                                                 scale <- case m_int_r64 of
                                                            Nothing     -> return v0_64
                                                            Just (i, r) -> bvTrunc n64 . bvMul (bvLit n64 i) <$> get (GPReg r)
                                                 return (base `bvAdd` scale `bvAdd` bvLit n64 i32)
    F.IP_Offset_64 seg i32                 -> do check_seg_value seg
                                                 bvAdd (bvLit n64 i32) <$> get IPReg
  where
    v0_64 = bvLit n64 (0 :: Int)
    check_seg_value seg
            | seg == F.cs || seg == F.ds || seg == F.es || seg == F.ss = return ()
            | otherwise                                                = fail "Segmentation is not supported"

-- | Extract the _location_ of a value, not the value contained.
getSomeBVLocation :: FullSemantics m => F.Value -> m (SomeBV (MLocation m))
getSomeBVLocation v =
  case v of
    F.ControlReg cr     -> mk (CReg cr)
    F.DebugReg dr       -> mk (DReg dr)
    F.MMXReg mmx        -> mk (MMXReg mmx)
    F.XMMReg xmm        -> mk (XMMReg xmm)
    F.SegmentValue s    -> mk (SegmentReg s)
    F.FarPointer _      -> fail "FarPointer"
    F.VoidMem ar        -> getBVAddress ar >>= mk . mkBVAddr n8 -- FIXME: what size here?
    F.Mem8  ar          -> getBVAddress ar >>= mk . mkBVAddr n8 -- FIXME: what size here?
    F.Mem16 ar          -> getBVAddress ar >>= mk . mkBVAddr n16
    F.Mem32 ar          -> getBVAddress ar >>= mk . mkBVAddr n32
    F.Mem64 ar          -> getBVAddress ar >>= mk . mkBVAddr n64
    F.ByteReg  r
      | Just r64 <- F.is_low_reg r  -> mk (reg_low8  r64)
      | Just r64 <- F.is_high_reg r -> mk (reg_high8 r64)
      | otherwise                   -> fail "unknown r8"
    F.WordReg  r                    -> mk (reg_low16 (F.reg16_reg r))
    F.DWordReg r                    -> mk (reg_low32 (F.reg32_reg r))
    F.QWordReg r                    -> mk (GPReg r)
    -- ByteImm  Word8
    -- WordImm  Word16
    -- DWordImm Word32
    -- QWordImm Word64
    -- JumpOffset Int64
    _                 -> fail "Immediate is not a location"
  where
    mk :: forall m n. (FullSemantics m, SupportedBVWidth n) => MLocation m (BVType n) -> m (SomeBV (MLocation m))
    mk = return . SomeBV

checkEqBV :: Monad m  => (forall n'. f (BVType n') -> NatRepr n') -> NatRepr n -> f (BVType p) -> m (f (BVType n))
checkEqBV getW n v
  | Just Refl <- testEquality (getW v) n = return v
  | otherwise                            = fail $ "Widths aren't equal: " ++ show (getW v) ++ " and " ++ show n

checkSomeBV :: Monad m  => (forall n'. f (BVType n') -> NatRepr n') -> NatRepr n -> SomeBV f -> m (f (BVType n))
checkSomeBV getW n (SomeBV v) = checkEqBV getW n v

truncateBVValue :: (Monad m, IsValue v)  => NatRepr n -> v (BVType n') -> m (v (BVType n))
truncateBVValue n v
  | Just LeqProof <- testLeq n (bv_width v) = return (bvTrunc n v)
  | otherwise                               = fail $ "Widths isn't >=: " ++ show (bv_width v) ++ " and " ++ show n

truncateBVLocation :: (Semantics m)
                   => NatRepr n -> MLocation m (BVType n') -> m (MLocation m (BVType n))
truncateBVLocation = undefined
--TODO: Implement this using lowerHalf/upperHalf if possible.
{-
truncateBVLocation n v
  | Just LeqProof <- testLeq n (loc_width v) =
      return (BVSlice v 0 n)
  | otherwise                                = fail $ "Widths isn't >=: " ++ show (loc_width v) ++ " and " ++ show n
-}


unimplemented :: Monad m => m ()
unimplemented = fail "UNIMPLEMENTED"

-- | This function executes a single instruction.
--
-- We divide instructions into
--   * regular:   those which take arguments of the same, polymorphic, width
--   * irrugular: those which have particular parsing requirements
--   * fixed:     those which have exact sizes known
execInstruction :: FullSemantics m => F.InstructionInstance -> m ()
execInstruction ii =
  case F.iiOp ii of
    -- irregular instructions
    "lea" | [loc, F.VoidMem ar] <- F.iiArgs ii
             -> do SomeBV l <- getSomeBVLocation loc
                   -- ensure that the location is at most 64 bits
                   Just LeqProof <- return $ testLeq (loc_width l) n64
                   v <- getBVAddress ar
                   exec_lea l (bvTrunc (loc_width l) v)
    "call"   -> maybe_ip_relative really_exec_call
    "imul"
      | length (F.iiArgs ii) == 1       -> unopV exec_imul1
      | length (F.iiArgs ii) == 2       -> binop (\l v' -> do { v <- get l; exec_imul2_3 l v v' })
      | [loc, val, val'] <- F.iiArgs ii -> do SomeBV l <- getSomeBVLocation loc
                                              v  <- getSomeBVValue val  >>= checkSomeBV bv_width (loc_width l)
                                              v' <- getSomeBVValue val' >>= checkSomeBV bv_width (loc_width l)
                                              exec_imul2_3 l v v'
                                              
    "jmp"    -> maybe_ip_relative exec_jmp_absolute
    "movsx"  -> geBinop exec_movsx_d
    "movsxd" -> geBinop exec_movsx_d
    "movzx"  -> geBinop exec_movzx
    "xchg"   -> mkBinop $ \v v' -> do SomeBV l <- getSomeBVLocation v
                                      l' <- getSomeBVLocation v' >>= checkSomeBV loc_width (loc_width l)
                                      exec_xchg l l'
    -- conditional instructions
    -- CMOVcc
    _ | Just f <- isConditional "cmov"
             -> binop (exec_cmovcc f)
    -- Jcc
    _ | Just f <- isConditional "j", [v] <- F.iiArgs ii
             -> getSomeBVValue v >>= checkSomeBV bv_width knownNat >>= exec_jcc f
    -- SETcc
    _ | Just f <- isConditional "set", [v] <- F.iiArgs ii
             -> getSomeBVLocation v >>= checkSomeBV loc_width knownNat >>= exec_setcc f
    -- fixed size instructions
    "addsd"   -> truncateKnownBinop exec_addsd
    "movapd"  -> truncateKnownBinop exec_movapd
    "movaps"  -> truncateKnownBinop exec_movapd
    "movsd"   -> truncateKnownBinop exec_movss
    "movss"   -> truncateKnownBinop exec_movss
    -- regular instructions
    "add"     -> binop exec_add
    "adc"     -> binop exec_adc
    "and"     -> binop exec_and
    "bsf"     -> binop exec_bsf
    "bsr"     -> binop exec_bsr
    "bswap"   -> unop  exec_bswap
    "cbw"     -> exec_cbw
    "cwde"    -> exec_cwde
    "cdqe"    -> exec_cdqe
    "clc"     -> exec_clc
    "cld"     -> exec_cld
    "cmp"     -> binop exec_cmp
    "dec"     -> unop exec_dec
    "inc"     -> unop exec_inc
    "leave"   -> exec_leave
    "mov"     -> binop exec_mov
    "mul"     -> unopV exec_mul
    "neg"     -> unop exec_neg
    "nop"     -> return ()
    "not"     -> unop exec_not
    "or"      -> binop exec_or
    "pause"   -> return ()
    "pop"     -> unop exec_pop
    "push"    -> unopV exec_push
    "ret"     -> exec_ret Nothing
    "ret_imm" | [F.WordImm imm] <- F.iiArgs ii
              -> exec_ret (Just imm)
    "sbb"     -> binop exec_sbb
    "sub"     -> binop exec_sub
    "syscall" -> get rax >>= syscall 
    "test"    -> binop exec_test
    "xor"     -> binop exec_xor
    _         -> fail $ "Unsupported instruction: " ++ show ii
  where
    -- conditional instruction support (cmovcc, jcc)
    conditionals = [ ("a", cond_a),   ("ae", cond_ae), ("b", cond_b),   ("be", cond_be), ("g", cond_g),
                     ("ge", cond_ge), ("l", cond_l),   ("le", cond_le), ("o", cond_o),   ("p", cond_p),
                     ("s", cond_s),   ("z", cond_z),   ("no", cond_no), ("np", cond_np), ("ns", cond_ns),
                     ("nz", cond_nz) ]
    isConditional pfx
      | Just p <- stripPrefix pfx (F.iiOp ii)  = lookup p conditionals
      | otherwise                              = Nothing

    maybe_ip_relative f
      | [F.JumpOffset off] <- F.iiArgs ii
           = do next_ip <- bvAdd (bvLit n64 off) <$> get IPReg
                f next_ip
      | [v]                <- F.iiArgs ii
           = getSomeBVValue v >>= checkSomeBV bv_width knownNat >>= f

      | otherwise  = fail "wrong number of operands"

    mkBinop :: FullSemantics m
            => (F.Value -> F.Value -> m a)
            -> m a
    mkBinop f = case F.iiArgs ii of
                  [v, v']   -> f v v'
                  vs        -> fail $ "expecting 2 arguments, got " ++ show (length vs)

    mkBinopLV :: FullSemantics m
            => (forall n n'. (1 <= n') => MLocation m (BVType n) -> Value m (BVType n') -> m a)
            -> m a
    mkBinopLV f = case F.iiArgs ii of
                    [loc, val] -> do SomeBV l <- getSomeBVLocation loc
                                     SomeBV v <- getSomeBVValue val
                                     f l v
                    vs         -> fail $ "expecting 2 arguments, got " ++ show (length vs)

    -- The location size must be >= the value size.
    geBinop :: FullSemantics m
            => (forall n n'. (1 <= n', n' <= n)
                           => MLocation m (BVType n) -> Value m (BVType n') -> m ())
            -> m ()
    geBinop f = mkBinopLV $ \l v -> do
                  Just LeqProof <- return $ testLeq (bv_width v) (loc_width l)
                  f l v

    truncateKnownBinop :: (KnownNat n, KnownNat n', FullSemantics m)
                       => (MLocation m (BVType n) -> Value m (BVType n') -> m ())
                       -> m ()
    truncateKnownBinop f = mkBinopLV $ \l v -> do
      l' <- truncateBVLocation knownNat l
      v' <- truncateBVValue knownNat v
      f l' v'

    knownBinop :: (KnownNat n, KnownNat n', FullSemantics m) => (MLocation m (BVType n) -> Value m (BVType n') -> m ()) -> m ()
    knownBinop f = mkBinop $ \loc val -> do l  <- getSomeBVLocation loc >>= checkSomeBV loc_width knownNat
                                            v  <- getSomeBVValue val >>= checkSomeBV bv_width knownNat
                                            f l v

    unopV :: FullSemantics m => (forall n. IsLocationBV m n => Value m (BVType n) -> m ()) -> m ()
    unopV f = case F.iiArgs ii of
                [val] -> do SomeBV v <- getSomeBVValue val
                            f v
                vs    -> fail $ "unop: expecting 1 argument, got " ++ show (length vs)

    unop :: FullSemantics m => (forall n. IsLocationBV m n => MLocation m (BVType n) -> m ()) -> m ()
    unop f = case F.iiArgs ii of
               [loc] -> do SomeBV l <- getSomeBVLocation loc
                           f l
               vs    -> fail $ "unop: expecting 1 argument, got " ++ show (length vs)

    binop :: FullSemantics m => (forall n. IsLocationBV m n => MLocation m (BVType n) -> Value m (BVType n) -> m ()) -> m ()
    binop f = case F.iiArgs ii of
                [loc, val] -> do SomeBV l <- getSomeBVLocation loc
                                 v <- getSomeBVValue val >>= checkSomeBV bv_width (loc_width l)
                                 f l v
                vs         -> fail $ "binop: expecting 2 arguments, got " ++ show (length vs)
