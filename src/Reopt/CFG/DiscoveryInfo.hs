{-|
Module     : Reopt.CFG.DiscoveryInfo
Copyright  : (c) Galois, Inc 2016
Maintainer : jhendrix@galois.com

This defines the information learned during the code discovery phase of Reopt.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
module Reopt.CFG.DiscoveryInfo
  ( BlockRegion(..)
  , lookupBlock
  , GlobalDataInfo(..)
  , ParsedTermStmt(..)
    -- * The interpreter state
  , DiscoveryInfo
  , emptyDiscoveryInfo
  , archInfo
  , memory
  , symbolNames
  , genState
  , blocks
  , functionEntries
  , reverseEdges
  , globalDataMap
    -- * Frontier
  , FrontierReason(..)
  , frontier
  , function_frontier
    -- ** Abstract state information
  , absState
  , AbsStateMap
  , lookupAbsBlock
    -- ** DiscoveryInfo utilities
  , getFunctionEntryPoint
  , inSameFunction
  , identifyCall
  , identifyReturn
  , classifyBlock
  , getClassifyBlock
  )  where

import           Control.Lens
import           Control.Monad (join)
import qualified Data.ByteString as BS
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Parameterized.Classes
import           Data.Parameterized.Some
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Vector as V
import           Data.Word
import           Numeric (showHex)
import           Text.PrettyPrint.ANSI.Leijen (Pretty(..))

import           Data.Macaw.CFG
import           Data.Macaw.Types

import           Reopt.Analysis.AbsState
import           Reopt.CFG.ArchitectureInfo
import           Reopt.Machine.SysDeps.Types
import           Reopt.Object.Memory
import           Reopt.Utils.Debug

------------------------------------------------------------------------
-- AbsStateMap

-- | Maps each code address to a set of abstract states
type AbsStateMap arch = Map (ArchAddr arch) (AbsBlockState arch)

lookupAbsBlock :: ( Ord (ArchAddr arch)
                  , Integral (ArchAddr arch)
                  , Show (ArchAddr arch)
                  )
                  => ArchAddr arch
                  -> AbsStateMap arch
                  -> AbsBlockState arch
lookupAbsBlock addr s = fromMaybe (error msg) (Map.lookup addr s)
  where msg = "Could not find block " ++ showHex addr "."

------------------------------------------------------------------------
-- BlockRegion

-- | The blocks contained in a single contiguous region of instructions.
data BlockRegion arch
   = BlockRegion { brEnd :: !(ArchAddr arch)
                 , brBlocks :: !(Map Word64 (Block arch))
                   -- ^ Map from labelIndex to associated block.
                 }

-- | Does a simple lookup in the cfg at a given DecompiledBlock address.
lookupBlock :: Ord (ArchAddr arch)
            => Map (ArchAddr arch) (Maybe (BlockRegion arch))
            -> ArchLabel arch
            -> Maybe (Block arch)
lookupBlock m lbl = do
  br <- join $ Map.lookup (labelAddr lbl) m
  Map.lookup (labelIndex lbl) (brBlocks br)

------------------------------------------------------------------------
-- FrontierReason

-- | Data describing why an address was added to the frontier.
data FrontierReason w
   = InInitialData
     -- ^ Exploring because a pointer to this address was found stored in
     -- memory.
   | InWrite       !(BlockLabel w)
     -- ^ Exploring because the given block writes it to memory.
   | ReturnAddress !(BlockLabel w)
     -- ^ Exploring because the given block stores address as a
     -- return address.
   | NextIP !(BlockLabel w)
     -- ^ Exploring because the given block jumps here.
   | StartAddr
     -- ^ Added as the initial start state.
   | BlockSplit
     -- ^ Added because a previous block split this block.
  deriving (Show)

------------------------------------------------------------------------
-- GlobalDataInfo

data GlobalDataInfo w
     -- | A jump table that appears to end just before the given address.
   = JumpTable !(Maybe w)
     -- | Some value that appears in the program text.
   | ReferencedValue

instance (Integral w, Show w) => Show (GlobalDataInfo w) where
  show (JumpTable Nothing) = "unbound jump table"
  show (JumpTable (Just w)) = "jump table end " ++ showHex w ""
  show ReferencedValue = "global addr"

------------------------------------------------------------------------
-- ParsedTermStmt

-- | This term statement is used to describe higher level expressions
-- of how block ending with a a FetchAndExecute statement should be
-- interpreted.
data ParsedTermStmt arch
   = ParsedCall !(RegState arch (Value arch))
                !(Seq (Stmt arch))
                -- ^ Statements less the pushed return value, if any
                !(Either (ArchAddr arch) (BVValue arch (ArchAddrWidth arch)))
                -- ^ Function to call.  If it is statically known,
                -- then we get Left, otherwise Right
                !(Maybe (ArchAddr arch))
                -- ^ Return location, Nothing if a tail call.
     -- | A jump within a block
   | ParsedJump !(RegState arch (Value arch)) !(ArchAddr arch)
     -- | A lookup table that branches to the given locations.
   | ParsedLookupTable !(RegState arch (Value arch))
                       !(BVValue arch (ArchAddrWidth arch))
                       !(V.Vector (ArchAddr arch))
     -- | A tail cthat branches to the given locations.
   | ParsedReturn !(RegState arch (Value arch)) !(Seq (Stmt arch))
     -- | A branch (i.e., BlockTerm is Branch)
   | ParsedBranch !(Value arch BoolType) !(ArchLabel arch) !(ArchLabel arch)
   | ParsedSyscall !(RegState arch (Value arch))
                   !(ArchAddr arch)
                   !(ArchAddr arch)
                   !String
                   !String
                   ![ArchReg arch (BVType (ArchAddrWidth arch))]
                   ![Some (ArchReg arch)]

deriving instance
  ( Integral (ArchAddr arch)
  , Show (ArchAddr arch)
  , HasRepr (ArchFn arch) TypeRepr
  , PrettyF (ArchFn arch)
  , Show (ArchReg arch (BVType (ArchAddrWidth arch)))
  , OrdF (ArchReg arch)
  , ShowF (ArchReg arch)
  , Pretty (ArchStmt arch)
  )
  => Show (ParsedTermStmt arch)

------------------------------------------------------------------------
-- DiscoveryInfo

-- | The state of the interpreter
data DiscoveryInfo arch
   = DiscoveryInfo { memory   :: !(Memory (ArchAddr arch))
                     -- ^ The initial memory when disassembly started.
                   , symbolNames :: Map (ArchAddr arch) BS.ByteString
                     -- ^ The set of symbol names (not necessarily complete)
                   , syscallPersonality :: !(SyscallPersonality arch)
                     -- ^ Syscall personailty, mainly used by getClassifyBlock etc.
                   , archInfo :: !(ArchitectureInfo arch)
                     -- ^ Architecture-specific information needed for discovery.
                   , _genState :: !AssignId
                   -- ^ Next index to use for generating an assignment.
                   -- | Intervals maps code addresses to blocks at address
                   -- or nothing if disassembly failed.
                   , _blocks   :: !(Map (ArchAddr arch) (Maybe (BlockRegion arch)))
                   , _functionEntries :: !(Set (ArchAddr arch))
                      -- ^ Maps addresses that are marked as the start of a function
                   , _reverseEdges :: !(Map (ArchAddr arch) (Set (ArchAddr arch)))
                     -- ^ Maps each code address to the list of predecessors that
                     -- affected its abstract state.
                   , _globalDataMap :: !(Map (ArchAddr arch) (GlobalDataInfo (ArchAddr arch)))
                     -- ^ Maps each address that appears to be global data to information
                     -- inferred about it.
                   , _frontier :: !(Map (ArchAddr arch) (FrontierReason (ArchAddr arch)))
                     -- ^ Set of addresses to explore next.
                     --
                     -- This is a map so that we can associate a reason why a code address
                     -- was added to the frontier.
                   , _function_frontier :: !(Set (ArchAddr arch))
                     -- ^ Set of functions to explore next.
                   , _absState :: !(AbsStateMap arch)
                     -- ^ Map from code addresses to the abstract state at the start of
                     -- the block.
                   }

-- | Empty interpreter state.
emptyDiscoveryInfo :: Memory (ArchAddr arch)
                   -> Map (ArchAddr arch) BS.ByteString
                   -> SyscallPersonality arch
                   -> ArchitectureInfo arch
                      -- ^ Stack delta
                   -> DiscoveryInfo arch
emptyDiscoveryInfo mem symbols sysp info = DiscoveryInfo
      { memory             = mem
      , symbolNames        = symbols
      , syscallPersonality = sysp
      , archInfo           = info
      , _genState          = 0
      , _blocks            = Map.empty
      , _functionEntries   = Set.empty
      , _reverseEdges      = Map.empty
      , _globalDataMap     = Map.empty
      , _frontier          = Map.empty
      , _function_frontier = Set.empty
      , _absState          = Map.empty
      }

-- | Next id to use for generating assignments
genState :: Simple Lens (DiscoveryInfo arch) AssignId
genState = lens _genState (\s v -> s { _genState = v })

blocks :: Simple Lens (DiscoveryInfo arch) (Map (ArchAddr arch) (Maybe (BlockRegion arch)))
blocks = lens _blocks (\s v -> s { _blocks = v })

-- | Addresses that start each function.
functionEntries :: Simple Lens (DiscoveryInfo arch) (Set (ArchAddr arch))
functionEntries = lens _functionEntries (\s v -> s { _functionEntries = v })

reverseEdges :: Simple Lens (DiscoveryInfo arch)
                            (Map (ArchAddr arch) (Set (ArchAddr arch)))
reverseEdges = lens _reverseEdges (\s v -> s { _reverseEdges = v })

-- | Map each jump table start to the address just after the end.
globalDataMap :: Simple Lens (DiscoveryInfo arch)
                             (Map (ArchAddr arch) (GlobalDataInfo (ArchAddr arch)))
globalDataMap = lens _globalDataMap (\s v -> s { _globalDataMap = v })

-- | Set of addresses to explore next.
--
-- This is a map so that we can associate a reason why a code address
-- was added to the frontier.
frontier :: Simple Lens (DiscoveryInfo arch)
                        (Map (ArchAddr arch) (FrontierReason (ArchAddr arch)))
frontier = lens _frontier (\s v -> s { _frontier = v })

-- | Set of functions to explore next.
function_frontier :: Simple Lens (DiscoveryInfo arch) (Set (ArchAddr arch))
function_frontier = lens _function_frontier (\s v -> s { _function_frontier = v })

absState :: Simple Lens (DiscoveryInfo arch) (AbsStateMap arch)
absState = lens _absState (\s v -> s { _absState = v })

------------------------------------------------------------------------
-- DiscoveryInfo utilities

-- | Constraint on architecture addresses needed by code exploration.
type AddrConstraint a = (Ord a, Integral a, Show a, Num a)

-- | Returns the guess on the entry point of the given function.
getFunctionEntryPoint :: AddrConstraint (ArchAddr a)
                      => ArchAddr a
                      -> DiscoveryInfo a
                      -> ArchAddr a
getFunctionEntryPoint addr s = do
  case Set.lookupLE addr (s^.functionEntries) of
    Just a -> a
    Nothing -> error $ "Could not find address of " ++ showHex addr "."

getFunctionEntryPoint' :: Ord (ArchAddr a) => ArchAddr a -> DiscoveryInfo a -> Maybe (ArchAddr a)
getFunctionEntryPoint' addr s = Set.lookupLE addr (s^.functionEntries)

inSameFunction :: AddrConstraint (ArchAddr a)
                  => ArchAddr a
                  -> ArchAddr a
                  -> DiscoveryInfo a
                  -> Bool
inSameFunction x y s =
  getFunctionEntryPoint x s == getFunctionEntryPoint y s

-- | Constraint on architecture register values needed by code exploration.
type RegConstraint r = (OrdF r, HasRepr r TypeRepr, RegisterInfo r, ShowF r)

-- | Constraint on architecture so that we can do code exploration.
type ArchConstraint a = ( AddrConstraint (ArchAddr a)
                        , RegConstraint (ArchReg a)
                        , HasRepr (ArchFn a) TypeRepr
                        )

-- | @isWriteTo stmt add tpr@ returns 'Just v' if @stmt@ writes 'v'
-- to @addr@ with a write having the given type 'tpr',  and 'Nothing' otherwise.
isWriteTo :: ArchConstraint a
          => Stmt a
          -> BVValue a (ArchAddrWidth a)
          -> TypeRepr tp
          -> Maybe (Value a tp)
isWriteTo (WriteMem a val) expected tp
  | Just _ <- testEquality a expected
  , Just Refl <- testEquality (typeRepr val) tp =
    Just val
isWriteTo _ _ _ = Nothing

-- | @isCodeAddrWriteTo mem stmt addr@ returns true if @stmt@ writes
-- a single address to a marked executable in @mem@ to @addr@.
isCodeAddrWriteTo :: ArchConstraint a
                  => Memory (ArchAddr a)
                  -> Stmt a
                  -> BVValue a (ArchAddrWidth a)
                  -> Maybe (ArchAddr a)
isCodeAddrWriteTo mem (WriteMem a (BVValue w val)) sp
  |  -- Check that address written matches expected
    Just _ <- testEquality a sp
    -- Check that write size matches the width of addresses
    -- in the architecture.
  , Just Refl <- testEquality w (valueWidth sp)
    -- Check that value written is in code.
  , isCodeAddr mem (fromInteger val)
  = Just (fromInteger val)
isCodeAddrWriteTo mem s sp
  | Just (BVValue _ val) <- isWriteTo s sp (knownType :: TypeRepr (BVType 64))
  , isCodeAddr mem (fromInteger val)
  = Just (fromInteger val)
isCodeAddrWriteTo _ _ _ = Nothing

-- | Attempt to identify the write to a stack return address, returning
-- instructions prior to that write and return  values.
--
-- This can also return Nothing if the call is not supported.
identifyCall :: (ArchConstraint a, RegisterInfo (ArchReg a))
             => Memory (ArchAddr a)
             -> [Stmt a]
             -> RegState a (Value a)
             -> Maybe (Seq (Stmt a), (ArchAddr a))
identifyCall mem stmts0 s = go (Seq.fromList stmts0)
  where -- Get value of stack pointer
        next_sp = s^.boundValue sp_reg
        -- Recurse on statements.
        go stmts =
          case Seq.viewr stmts of
            Seq.EmptyR -> Nothing
            prev Seq.:> stmt
                -- Check if we have reached the write of the return address to the
                -- stack pointer.
              | Just ret <- isCodeAddrWriteTo mem stmt next_sp ->
                Just (prev, ret)
                -- Stop if we hit any architecture specific instructions prior to
                -- identifying return address since they may have side effects.
              | ExecArchStmt _ <- stmt -> Nothing
                -- Otherwise skip over this instruction.
              | otherwise -> go prev

-- | This is designed to detect returns from the register state representation.
--
-- It pattern matches on a 'RegState' to detect if it read its instruction
-- pointer from an address that is 8 below the stack pointer.
--
-- Note that this assumes the stack decrements as values are pushed, so we will
-- need to fix this on other architectures.
identifyReturn :: ArchConstraint arch
               => RegState arch (Value arch)
               -> Integer
                  -- ^ How stack pointer moves when a call is made
               -> Maybe (Assignment arch (BVType (ArchAddrWidth arch)))
identifyReturn s stack_adj = do
  let next_ip = s^.boundValue ip_reg
      next_sp = s^.boundValue sp_reg
  case next_ip of
    AssignedValue asgn@(Assignment _ (ReadMem ip_addr _))
      | let (ip_base, ip_off) = asBaseOffset ip_addr
      , let (sp_base, sp_off) = asBaseOffset next_sp
      , (ip_base, ip_off) == (sp_base, sp_off + stack_adj) -> Just asgn
    _ -> Nothing

identifyJumpTable :: forall arch
                  .  (AddrConstraint (ArchAddr arch))
                  => DiscoveryInfo arch
                  -> ArchLabel arch
                      -- | Memory address that IP is read from.
                  -> BVValue arch (ArchAddrWidth arch)
                  -- Returns the (symbolic) index and concrete next blocks
                  -> Maybe (BVValue arch (ArchAddrWidth arch), V.Vector (ArchAddr arch))
identifyJumpTable s lbl (AssignedValue (Assignment _ (ReadMem ptr _)))
    -- Turn the read address into base + offset.
   | Just (BVAdd _ offset (BVValue _ base)) <- valueAsApp ptr
    -- Turn the offset into a multiple by an index.
   , Just (BVMul _ (BVValue _ mult) idx) <- valueAsApp offset
   , mult == toInteger (jumpTableEntrySize info)
   , isReadonlyAddr mem (fromInteger base) =
       Just (idx, V.unfoldr nextWord (fromInteger base))
  where
    enclosingFun    = getFunctionEntryPoint (labelAddr lbl) s
    nextWord :: ArchAddr arch -> Maybe (ArchAddr arch, ArchAddr arch)
    nextWord tblPtr
      | Right codePtr <- readAddrInMemory info mem pf_r tblPtr
      , isReadonlyAddr mem tblPtr
      , getFunctionEntryPoint' codePtr s == Just enclosingFun =
        Just (codePtr, tblPtr + jumpTableEntrySize info)
      | otherwise = Nothing
    info = archInfo s
    mem = memory s
identifyJumpTable _ _ _ = Nothing

-- | Classifies the terminal statement in a block using discovered information.
classifyBlock :: forall arch
              .  ArchConstraint arch
              => Block arch
              -> DiscoveryInfo arch
              -> Maybe (ParsedTermStmt arch)
classifyBlock b interp_state =
  case blockTerm b of
    Branch c x y -> Just (ParsedBranch c x y)
    FetchAndExecute proc_state
        -- The last statement was a call.
      | Just (prev_stmts, ret_addr) <- identifyCall mem (blockStmts b) proc_state ->
          let fptr = case proc_state^.boundValue ip_reg of
                       BVValue _ v -> Left (fromInteger v)
                       ip          -> Right ip
          in Just (ParsedCall proc_state prev_stmts fptr (Just ret_addr))

      -- Jump to concrete offset.
      | BVValue _ (fromInteger -> tgt_addr) <- proc_state^.boundValue ip_reg
      , inSameFunction (labelAddr (blockLabel b)) tgt_addr interp_state ->
           Just (ParsedJump proc_state tgt_addr)

      -- Return
      | Just asgn <- identifyReturn proc_state (stackDelta (archInfo interp_state)) ->
        let isRetLoad s =
              case s of
                AssignStmt asgn' | Just Refl <- testEquality asgn asgn' -> True
                _ -> False
            nonret_stmts = Seq.fromList $ filter (not . isRetLoad) (blockStmts b)

        in Just (ParsedReturn proc_state nonret_stmts)

      -- Tail calls to a concrete address (or, nop pads after a non-returning call)
      | BVValue _ (fromInteger -> tgt_addr) <- proc_state^.boundValue ip_reg ->
        Just (ParsedCall proc_state (Seq.fromList $ blockStmts b) (Left tgt_addr) Nothing)

      | Just (idx, nexts) <- identifyJumpTable interp_state (blockLabel b)
                                               (proc_state^.boundValue ip_reg) ->
          Just (ParsedLookupTable proc_state idx nexts)

      -- Finally, we just assume that this is a tail call through a pointer
      -- FIXME: probably unsound.
      | otherwise -> Just (ParsedCall proc_state
                                      (Seq.fromList $ blockStmts b)
                                      (Right $ proc_state^.boundValue ip_reg) Nothing)

    -- rax is concrete in the first case, so we don't need to propagate it etc.
    Syscall proc_state
      | BVValue _ next_addr <- proc_state^.boundValue ip_reg
      , BVValue _ call_no   <- proc_state^.boundValue syscall_num_reg
      , Just (name, _rettype, argtypes) <-
          Map.lookup (fromInteger call_no) (spTypeInfo sysp) -> do
         let syscallRegs :: [ArchReg arch (BVType (ArchAddrWidth arch))]
             syscallRegs = syscallArgumentRegs
         let result = Just $
               ParsedSyscall
                 proc_state
                 (fromInteger next_addr)
                 (fromInteger call_no)
                 (spName sysp)
                 name
                 (take (length argtypes) syscallRegs)
                 (spResultRegisters sysp)
         case () of
           _ | any ((/=) WordArgType) argtypes -> error "Got a non-word arg type"
           _ | length argtypes > length syscallRegs ->
                  debug DUrgent ("Got more than register args calling " ++ name
                                 ++ " in block " ++ show (blockLabel b))
                                result
           _ -> result

        -- FIXME: Should subsume the above ...
        -- FIXME: only works if rax is an initial register
      | BVValue _ next_addr <- proc_state^.boundValue ip_reg
      , Initial r <- proc_state^.boundValue syscall_num_reg
      , Just absSt <- Map.lookup (labelAddr $ blockLabel b) (interp_state ^. absState)
      , Just call_no <-
          asConcreteSingleton (absSt ^. absRegState ^. boundValue r)
      , Just (name, _rettype, argtypes) <-
          Map.lookup (fromInteger call_no) (spTypeInfo sysp) -> do
         let syscallRegs :: [ArchReg arch (BVType (ArchAddrWidth arch))]
             syscallRegs = syscallArgumentRegs
         let result = Just $
               ParsedSyscall
                 proc_state
                 (fromInteger next_addr)
                 (fromInteger call_no)
                 (spName sysp)
                 name
                 (take (length argtypes) syscallRegs)
                 (spResultRegisters sysp)
         case () of
           _ | any ((/=) WordArgType) argtypes -> error "Got a non-word arg type"
           _ | length argtypes > length syscallRegs ->
                 debug DUrgent ("Got more than register args calling " ++ name
                                ++ " in block " ++ show (blockLabel b))
                       result
           _ -> result


      | BVValue _ (fromInteger -> next_addr) <- proc_state^.boundValue ip_reg ->
          debug DUrgent ("Unknown syscall in block " ++ show (blockLabel b)
                         ++ " syscall number is "
                         ++ show (pretty $ proc_state^.boundValue syscall_num_reg)
                        )
          Just $ ParsedSyscall proc_state next_addr 0 (spName sysp) "unknown"
                               syscallArgumentRegs
                               (spResultRegisters sysp)
      | otherwise -> error "shouldn't get here"
  where
    mem = memory interp_state
    sysp = syscallPersonality interp_state

getClassifyBlock :: ArchConstraint arch
                 => ArchLabel arch
                 -> DiscoveryInfo arch
                 -> Maybe (Block arch, Maybe (ParsedTermStmt arch))
getClassifyBlock lbl interp_state = do
  b <- lookupBlock (interp_state ^. blocks) lbl
  return (b, classifyBlock b interp_state)
