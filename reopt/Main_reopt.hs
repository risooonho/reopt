{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
module Main (main) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Control.Monad.State.Strict
import qualified Data.ByteString as B
import           Data.Elf
import           Data.Foldable (traverse_)
import           Data.Int
import           Data.List
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word
import           Data.Version
import           GHC.TypeLits
import           Numeric (showHex)
import           Reopt.Analysis.AbsState
import           System.Console.CmdArgs.Explicit
import           System.Environment (getArgs)
import           System.Exit (exitFailure)
import           System.IO
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF

import           Paths_reopt (version)
import           Data.Type.Equality as Equality

import           Flexdis86 (InstructionInstance(..))
import           Reopt
import           Reopt.CFG.CFGDiscovery
import           Reopt.CFG.Representation
import qualified Reopt.Machine.StateNames as N
import           Reopt.Machine.Types
import           Reopt.Object.Loader
import           Reopt.Object.Memory
import           Reopt.Semantics.DeadRegisterElimination
import           Reopt.Semantics.Monad (Type(..))

------------------------------------------------------------------------
-- Args

-- | Action to perform when running
data Action
   = DumpDisassembly -- ^ Print out disassembler output only.
   | ShowCFG         -- ^ Print out control-flow microcode.
   | ShowCFGAI       -- ^ Print out control-flow microcode + abs domain
   | ShowGaps        -- ^ Print out gaps in discovered blocks
   | ShowHelp        -- ^ Print out help message
   | ShowVersion     -- ^ Print out version

-- | Command line arguments.
data Args = Args { _reoptAction :: !Action
                 , _programPath :: !FilePath
                 , _loadStyle   :: !LoadStyle
                 }

-- | How to load Elf file.
data LoadStyle
   = LoadBySection
     -- ^ Load loadable sections in Elf file.
   | LoadBySegment
     -- ^ Load segments in Elf file.

-- | Action to perform when running.
reoptAction :: Simple Lens Args Action
reoptAction = lens _reoptAction (\s v -> s { _reoptAction = v })

-- | Path to load
programPath :: Simple Lens Args FilePath
programPath = lens _programPath (\s v -> s { _programPath = v })

-- | Whether to load file by segment or sections.
loadStyle :: Simple Lens Args LoadStyle
loadStyle = lens _loadStyle (\s v -> s { _loadStyle = v })

-- | Initial arguments if nothing is specified.
defaultArgs :: Args
defaultArgs = Args { _reoptAction = ShowCFG
                   , _programPath = ""
                   , _loadStyle = LoadBySection
                   }

------------------------------------------------------------------------
-- Argument processing

disassembleFlag :: Flag Args
disassembleFlag = flagNone [ "disassemble", "d" ] upd help
  where upd  = reoptAction .~ DumpDisassembly
        help = "Disassemble code segment of binary, and print it in an objdump style."

cfgFlag :: Flag Args
cfgFlag = flagNone [ "cfg", "c" ] upd help
  where upd  = reoptAction .~ ShowCFG
        help = "Print out recovered control flow graph of executable."

cfgAIFlag :: Flag Args
cfgAIFlag = flagNone [ "ai", "a" ] upd help
  where upd  = reoptAction .~ ShowCFGAI
        help = "Print out recovered control flow graph + AI of executable."

gapFlag :: Flag Args
gapFlag = flagNone [ "gap", "g" ] upd help
  where upd  = reoptAction .~ ShowGaps
        help = "Print out gaps in the recovered  control flow graph of executable."

segmentFlag :: Flag Args
segmentFlag = flagNone [ "load-segments" ] upd help
  where upd  = loadStyle .~ LoadBySegment
        help = "Load the Elf file using segment information."

sectionFlag :: Flag Args
sectionFlag = flagNone [ "load-sections" ] upd help
  where upd  = loadStyle .~ LoadBySection
        help = "Load the Elf file using section information (default)."

arguments :: Mode Args
arguments = mode "reopt" defaultArgs help filenameArg flags
  where help = reoptVersion ++ "\n" ++ copyrightNotice
        flags = [ disassembleFlag
                , cfgFlag
                , cfgAIFlag
                , gapFlag
                , segmentFlag
                , sectionFlag
                , flagHelpSimple (reoptAction .~ ShowHelp)
                , flagVersion (reoptAction .~ ShowVersion)
                ]

reoptVersion :: String
reoptVersion = "Reopt binary reoptimizer (reopt) "
             ++ versionString ++ ", June 2014."
  where [h,l,r] = versionBranch version
        versionString = show h ++ "." ++ show l ++ "." ++ show r

copyrightNotice :: String
copyrightNotice = "Copyright 2014 Galois, Inc. All rights reserved."

filenameArg :: Arg Args
filenameArg = Arg { argValue = setFilename
                  , argType = "FILE"
                  , argRequire = False
                  }
  where setFilename :: String -> Args -> Either String Args
        setFilename nm a = Right (a & programPath .~ nm)

getCommandLineArgs :: IO Args
getCommandLineArgs = do
  argStrings <- getArgs
  case process arguments argStrings of
    Left msg -> do
      putStrLn msg
      exitFailure
    Right v -> return v

------------------------------------------------------------------------
-- Execution

showUsage :: IO ()
showUsage = do
  putStrLn "For help on using reopt, run \"reopt --help\"."

readElf64 :: FilePath -> IO (Elf Word64)
readElf64 path = do
  when (null path) $ do
    putStrLn "Please specify a binary."
    showUsage
    exitFailure
  bs <- B.readFile path
  case parseElf bs of
    Left (_,msg) -> do
      putStrLn $ "Error reading " ++ path ++ ":"
      putStrLn $ "  " ++ msg
      exitFailure
    Right (Elf32 _) -> do
      putStrLn "32-bit executables are not yet supported."
      exitFailure
    Right (Elf64 e) ->
      return e

dumpDisassembly :: FilePath -> IO ()
dumpDisassembly path = do
  e <- readElf64 path
  let sections = filter isCodeSection $ e^..elfSections
  when (null sections) $ do
    putStrLn "Binary contains no executable sections."
  mapM_ printSectionDisassembly sections
  -- print $ Set.size $ instructionNames sections
  --print $ Set.toList $ instructionNames sections

readStaticElf :: FilePath -> IO (Elf Word64)
readStaticElf path = do
  e <- readElf64 path
  mi <- elfInterpreter e
  case mi of
    Nothing ->
      return ()
    Just{} ->
      fail "reopt does not yet support generating CFGs from dynamically linked executables."
  return e

isInterestingCode :: Memory Word64 -> (CodeAddr, Maybe CodeAddr) -> Bool
isInterestingCode mem (start, Just end) = go start end
  where
    isNop ii = (iiOp ii == "nop")
               || (iiOp ii == "xchg" &&
                   case iiArgs ii of
                    [x, y] -> x == y
                    _      -> False)

    go b e | b < e = case readInstruction mem b of
                      Left _           -> False -- FIXME: ignore illegal sequences?
                      Right (ii, next) -> not (isNop ii) || go next e
           | otherwise = False

isInterestingCode _ _ = True -- Last bit

showGaps :: Memory Word64 -> Word64 -> IO ()
showGaps mem entry = do
    let cfg = finalCFG (cfgFromAddress mem entry)
    let ends = cfgBlockEnds cfg
    let blocks = [ addr | GeneratedBlock addr 0 <- Map.keys (cfg ^. cfgBlocks) ]
    let gaps = filter (isInterestingCode mem)
             $ out_gap blocks (Set.elems ends)
    mapM_ (print . pretty . ppOne) gaps
  where
    ppOne (start, m_end) = text ("[" ++ showHex start "..") <>
                           case m_end of
                            Nothing -> text "END)"
                            Just e  -> text (showHex e ")")

    in_gap start bs@(b:_) ess = (start, Just b) : out_gap bs (dropWhile (<= b) ess)
    in_gap start [] _ = [(start, Nothing)]

    out_gap (b:bs') ess@(e:es')
      | b < e          = out_gap bs' ess
      | b == e         = out_gap bs' es'
    out_gap bs (e:es') = in_gap e bs es'
    out_gap _ _        = []

showCFG :: Memory Word64 -> Word64 -> IO ()
showCFG mem entry = do
  -- Get list of code locations to explore starting from entry points (i.e., eltEntry)
  let g0 = finalCFG (cfgFromAddress mem entry)
  let g = eliminateDeadRegisters g0
  print (pretty g)
{-
  putStrLn $ "Found potential calls: " ++ show (Map.size (cfgCalls g))

  let rCalls = reverseEdges (cfgCalls g)

  let rEdgeMap = reverseEdges (cfgSuccessors g)


  let sources = getTargets (Map.keys rCalls) rEdgeMap

  forM_ (Set.toList sources) $ \a -> do
    let Just b = findBlock g (GeneratedBlock a 0)
    when (hasCall b == False) $ do
      print $ "Found start " ++ showHex a ""
      print (pretty b)
-}

------------------------------------------------------------------------
-- Function determination

{-
A procedure is a contiguous set of blocks that:
 * Has a unique entry point.
 * Returns to the address stored at the address "sp".
-}


type AbsStack = Map Int64 Word64

emptyAbsStack :: AbsStack
emptyAbsStack = Map.empty


------------------------------------------------------------------------
-- Call detection


-- | @v `asOffsetOf` b@ returns @Just o@ if @v@ can be interpreted
-- as a constant offset from a term at base @b@, and @Nothing@
-- otherwise.
asOffsetOf :: Value tp -> Value tp -> Maybe Integer
asOffsetOf v base
  | v == base = Just 0
  | Just (BVAdd _ v' (BVValue _ o)) <- valueAsApp v
  , v' == base = Just o
  | otherwise = Nothing

runStmt :: Stmt -> State AbsStack ()
runStmt (Write (MemLoc a _) (BVValue _ v))
  | Just o <- a `asOffsetOf` (Initial N.rsp) = do
    modify $ Map.insert (fromInteger o) (fromInteger v)
runStmt _ = return ()

lookupStack :: Int64 -> AbsStack -> Maybe Word64
lookupStack o s = Map.lookup o s

decompiledBlocks :: CFG -> [Block]
decompiledBlocks g =
  [ b | b <- Map.elems (g^.cfgBlocks)
      , GeneratedBlock _ 0 <- [blockLabel b]
      ]

-- | Maps blocks to set of concrete addresses they may call.
type CallState = Map CodeAddr (Set CodeAddr)

addAddrs :: CodeAddr -> Value (BVType 64) -> State CallState ()
addAddrs b (BVValue _ o) =
  modify $ Map.insertWith Set.union b (Set.singleton (fromInteger o))
addAddrs _ _ = return ()

detectCalls :: CFG -> Block -> AbsStack -> State CallState ()
detectCalls g b initStack = do
  let finStack = flip execState initStack $
                   traverse_ runStmt (blockStmts b)
  case blockTerm b of
    FetchAndExecute x86_state -> do
      let rsp = x86_state^.register N.rsp
      case rsp `asOffsetOf` (Initial N.rsp) of
        Just o | Just _ <- lookupStack (fromInteger o) finStack -> do
          addAddrs (blockParent (blockLabel b)) (x86_state^.curIP)
        _ -> return ()
    Branch _ x y -> do
      let Just xb = findBlock g x
          Just yb = findBlock g y
      detectCalls g xb finStack
      detectCalls g yb finStack

cfgCalls :: CFG -> CallState
cfgCalls g = flip execState Map.empty $ do
  traverse_ (\b -> detectCalls g b emptyAbsStack) (decompiledBlocks g)

detectSuccessors :: CFG -> Block -> State CallState ()
detectSuccessors g b = do
  case blockTerm b of
    FetchAndExecute x86_state -> do
      addAddrs (blockParent (blockLabel b)) (x86_state^.curIP)
    Branch _ x y -> do
      let Just xb = findBlock g x
          Just yb = findBlock g y
      detectSuccessors g xb
      detectSuccessors g yb

cfgSuccessors :: CFG -> CallState
cfgSuccessors g = flip execState Map.empty $ do
  traverse_ (detectSuccessors g) (decompiledBlocks g)

toAllList :: Map a (Set b) -> [(a,b)]
toAllList m = do
  (k,s) <- Map.toList m
  v <- Set.toList s
  return (k,v)

reverseEdges :: Ord a => Map a (Set a) -> Map a (Set a)
reverseEdges m = flip execState Map.empty $ do
  forM_ (toAllList m) $ \(k,v) -> do
    modify $ Map.insertWith Set.union v (Set.singleton k)

getTargets :: (Ord a, Ord b) => [a] -> Map a (Set b) -> Set b
getTargets l m = foldl' Set.union Set.empty $
  fmap (fromMaybe Set.empty . (`Map.lookup` m)) l

------------------------------------------------------------------------
-- Pattern match on stack pointer possibilities.

printSP :: CFG -> Block -> IO ()
printSP g b = do
  let next = fmap (view (register N.rsp)) $ blockNextStates g b
  case nub next of
    [] -> hPutStrLn stderr $ "No rsp values for " ++ show (blockLabel b)
    _:_:_ -> hPutStrLn stderr $ "Multiple rsp values for " ++ show (blockLabel b)
    [rsp_val]
      | Initial v <- rsp_val
      , Just Refl <- testEquality v N.rsp ->
        return ()
      | Just (BVAdd _ (Initial r) BVValue{}) <- valueAsApp rsp_val
      , Just Refl <- testEquality r N.rsp -> do
        return ()
      | Just (BVAdd _ (Initial r) BVValue{}) <- valueAsApp rsp_val
      , Just Refl <- testEquality r N.rbp -> do
        return ()
      | otherwise -> do
        hPutStrLn stderr $ "Block " ++ show (pretty (blockLabel b))
        hPutStrLn stderr $ "RSP = " ++ show (pretty rsp_val)

{-
      let rbp_val = s^.register N.rbp
      case rbp_val of
           -- This leaves the base pointer unchanged.  It is likely an
           -- internal block.
        _ | Initial v <- rbp_val
          , Just Refl <- testEquality v N.rbp ->
            return ()
           -- This assigns the base pointer the current stack.
           -- It is likely a function entry point
        _ | Just (BVAdd _ (Initial r) BVValue{}) <- valueAsApp rbp_val
          , Just Refl <- testEquality r N.rsp -> do
            return ()
           -- This block assigns the base pointer a value from the stack.
           -- It is likely a function exit.
        _ | AssignedValue (assignRhs -> Read (MemLoc addr _)) <- rbp_val
          , Initial v <- addr
          , Just Refl <- testEquality v N.rbp -> do
            return ()
           -- This block assigns the base pointer a value from the stack.
           -- It is likely a function exit.
        _ | AssignedValue (assignRhs -> Read (MemLoc addr _)) <- rbp_val
          , Just (BVAdd _ (Initial v) BVValue{}) <- valueAsApp addr
          , Just Refl <- testEquality v N.rsp -> do
            return ()

        _ | otherwise -> do
            print $ "Block " ++ show (pretty (blockLabel b))
            print $ "RBP = " ++ show (pretty rbp_val)
-}

ppStmtAndAbs :: MapF Assignment AbsValue -> Stmt -> Doc
ppStmtAndAbs m stmt =
  case stmt of
    AssignStmt a ->
      case ppAbsValue =<< MapF.lookup a m of
        Just d -> vcat [ text "#" <+> ppAssignId (assignId a) <+> text ":=" <+> d
                       , pretty a
                       ]
        Nothing -> pretty a
    _ -> pretty stmt


ppBlockAndAbs :: MapF Assignment AbsValue -> Block -> Doc
ppBlockAndAbs m b =
  pretty (blockLabel b) <> text ":" <$$>
  indent 2 (vcat (ppStmtAndAbs m <$> blockStmts b) <$$>
            pretty (blockTerm b))


showCFGAndAI :: Memory Word64 -> Word64 -> IO ()
showCFGAndAI mem entry = do
  -- Build model of executable memory from elf.
  -- Get list of code locations to explore starting from entry points (i.e., eltEntry)
  let fg = cfgFromAddress mem entry
  let abst = finalAbsState fg
      amap = assignmentAbsValues mem fg
  let g  = eliminateDeadRegisters (finalCFG fg)
      ppOne b =
         vcat [case (blockLabel b, Map.lookup (blockParent (blockLabel b)) abst) of
                  (GeneratedBlock _ 0, Just ab) -> pretty ab
                  (GeneratedBlock _ 0, Nothing) -> text "Stored in memory"
                  (_,_) -> text ""

              , ppBlockAndAbs amap b
              ]
  print $ vcat (map ppOne $ Map.elems (g^.cfgBlocks))
  forM_ (Map.elems (g^.cfgBlocks)) $ \b -> do
    case blockLabel b of
      GeneratedBlock _ 0 -> do
        checkReturnsIdentified g b
      _ -> return ()
  forM_ (Map.elems (g^.cfgBlocks)) $ \b -> do
    case blockLabel b of
      GeneratedBlock _ 0 -> do
        checkCallsIdentified mem g b
      _ -> return ()

-- | This is designed to detect returns from the X86 representation.
-- It pattern matches on a X86State to detect if it read its instruction
-- pointer from an address that is 8 below the stack pointer.
stateEndsWithRet :: X86State Value -> Bool
stateEndsWithRet s = do
  let next_ip = s^.register N.rip
      next_sp = s^.register N.rsp
  case () of
    _ | AssignedValue (Assignment _ (Read (MemLoc a _))) <- next_ip
      , (ip_base, ip_off) <- asBaseOffset a
      , (sp_base, sp_off) <- asBaseOffset next_sp ->
        ip_base == sp_base && ip_off + 8 == sp_off
    _ -> False

-- | @isrWriteTo stmt add tpr@ returns true if @stmt@ writes to @addr@
-- with a write having the given type.
isWriteTo :: Stmt -> Value (BVType 64) -> TypeRepr tp -> Maybe (Value tp)
isWriteTo (Write (MemLoc a _) val) expected tp
  | Just _ <- testEquality a expected
  , Just Refl <- testEquality (valueType val) tp =
    Just val
isWriteTo _ _ _ = Nothing

-- | @isCodePointerWriteTo mem stmt addr@ returns true if @stmt@ writes
isCodePointerWriteTo :: Memory Word64 -> Stmt -> Value (BVType 64) -> Maybe Word64
isCodePointerWriteTo mem s sp
  | Just (BVValue _ val) <- isWriteTo s sp (knownType :: TypeRepr (BVType 64))
  , isCodePointer mem (fromInteger val)
  = Just (fromInteger val)
isCodePointerWriteTo _ _ _ = Nothing

-- | Returns true if it looks like block ends with a call.
blockContainsCall :: Memory Word64 -> Block -> X86State Value -> Bool
blockContainsCall mem b s =
  let next_sp = s^.register N.rsp
      go [] = False
      go (stmt:_) | Just _ <- isCodePointerWriteTo mem stmt next_sp = True
      go (Write _ _:_) = False
      go (_:r) = go r
   in go (reverse (blockStmts b))

-- | Return next states for block.
blockNextStates :: CFG -> Block -> [X86State Value]
blockNextStates g b =
  case blockTerm b of
    FetchAndExecute s -> [s]
    Branch _ x_lbl y_lbl -> blockNextStates g x ++ blockNextStates g y
      where Just x = findBlock g x_lbl
            Just y = findBlock g y_lbl
    Syscall _ -> []

checkReturnsIdentified :: CFG -> Block -> IO ()
checkReturnsIdentified g b = do
  case blockNextStates g b of
    [s] -> do
      let lbl = blockLabel b
      case (stateEndsWithRet s, hasRetComment b) of
        (True, True) -> return ()
        (True, False) -> do
          hPutStrLn stderr $ "UNEXPECTED return Block " ++ showHex (blockParent lbl) ""
        (False, True) -> do
          hPutStrLn stderr $ "MISSING return Block " ++ showHex (blockParent lbl) ""
        _ -> return ()
    _ -> return ()

checkCallsIdentified :: Memory Word64 -> CFG -> Block -> IO ()
checkCallsIdentified mem g b = do
  let lbl = blockLabel b
  case blockNextStates g b of
    [s] -> do
      case (blockContainsCall mem b s, hasCallComment b) of
        (True, False) -> do
          hPutStrLn stderr $ "UNEXPECTED call Block " ++ showHex (blockParent lbl) ""
        (False, True) -> do
          hPutStrLn stderr $ "MISSING call Block " ++ showHex (blockParent lbl) ""
        _ -> return ()
    _ -> return ()

mkElfMem :: (ElfWidth w, Functor m, Monad m) => LoadStyle -> Elf w -> m (Memory w)
mkElfMem LoadBySection e = memoryForElfSections e
mkElfMem LoadBySegment e = memoryForElfSegments e


main :: IO ()
main = do
  args <- getCommandLineArgs
  case args^.reoptAction of
    DumpDisassembly -> do
      dumpDisassembly (args^.programPath)
    ShowCFG -> do
      e <- readStaticElf (args^.programPath)
      mem <- mkElfMem (args^.loadStyle) e
      showCFG mem (elfEntry e)
    ShowCFGAI -> do
      e <- readStaticElf (args^.programPath)
      mem <- mkElfMem (args^.loadStyle) e
      showCFGAndAI mem (elfEntry e)
    ShowGaps -> do
      e <- readStaticElf (args^.programPath)
      mem <- mkElfMem (args^.loadStyle) e
      showGaps mem (elfEntry e)
    ShowHelp ->
      print $ helpText [] HelpFormatDefault arguments
    ShowVersion ->
      putStrLn (modeHelp arguments)
