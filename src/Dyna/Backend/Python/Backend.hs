---------------------------------------------------------------------------
-- | Compile to Python
--
-- See bin/interpreter.py

-- Header material                                                      {{{
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}

module Dyna.Backend.Python.Backend (pythonBackend) where

-- import           Control.Applicative ((<*))
-- import qualified Control.Arrow              as A
-- import           Control.Exception
import           Control.Lens ((^.))
import           Control.Monad
import           Control.Monad.State
-- import qualified Data.ByteString            as B
-- import qualified Data.ByteString.UTF8       as BU
-- import           Data.Char
-- import           Data.Either
-- import qualified Data.List                  as L
import qualified Data.Map                   as M
import qualified Data.Maybe                 as MA
-- import qualified Data.Ord                   as O
import qualified Data.Set                   as S
-- import qualified Debug.Trace                as XT
import           Dyna.Analysis.ANF
-- import           Dyna.Analysis.Aggregation
import           Dyna.Analysis.DOpAMine
import           Dyna.Analysis.Mode
import           Dyna.Analysis.RuleMode
import           Dyna.Backend.BackendDefn
import           Dyna.Main.Exception
import           Dyna.Term.TTerm
-- import qualified Dyna.ParserHS.Parser       as P
import           Dyna.XXX.PPrint
import           Dyna.XXX.MonadUtils
import           Dyna.XXX.Trifecta (prettySpanLoc)
import           System.IO
import           Text.PrettyPrint.Free
-- import qualified Text.Trifecta              as T

------------------------------------------------------------------------}}}
-- Supported aggregations                                               {{{

aggrs = S.fromList
  [ "max=" , "min="
  , "+=" , "*="
  , "and=" , "or=" , "&=" , "|="
  , ":-"
  , "majority=" , "set=" , "bag="
  , ":="
  , "dict="
  ]


------------------------------------------------------------------------}}}
-- DOpAMine Backend Information                                         {{{

-- | We can optionally attach a function to an 'OPIter' call,
-- which lets us permute arguments and so on when we go to do code
-- generation without having to re-probe the modes.
newtype PyDopeBS = PDBS (forall e . ModedVar -> [ModedVar] -> Doc e)

nfree, nuniv :: NIX DFunct
nfree = nHide IFree
nuniv = nHide (IUniv UShared)

isGround, isFree :: ModedVar -> Bool
isGround v = nGround (v^.mv_mi)
isFree v = nSub (v^.mv_mi) nfree

builtins :: BackendPossible PyDopeBS
builtins (f,is,o) = case () of
  _ | all isGround is
    -> maybe (Left False) gencall $ constants (f,length is)
        where
         gencall pc = case () of
                        _ | isFree o ->
                         Right $ BAct [OPIter o is f Det (Just pc)]
                                      [(o^.mv_var, nuniv)]
                        _ | isGround o ->
                          let chkv = "_chk"
                              fchk = MV chkv nfree nuniv
                          in Right $ BAct [ OPIter fchk is f Det (Just pc)
                                          , OPCheq chkv (o^.mv_var) ]
                                          []
                        _ -> Left True

  -- XXX These next two branches have nothing specific about Python at all
  -- and shouldn't be here.  Similarly, the corresponding entries in
  -- NoBackend also shouldn't be around (possibly).  These should be handled
  -- much more generically earlier in the pipeline.
  _ | f == "+" && isGround o
    -> case is of
         [x,y] | isGround x && isFree y
               -> Right $ BAct [OPIter y [o,x] "-" Det (Just$ PDBS$ infixOp "-")]
                               [(y^.mv_var, nuniv)]
         [x,y] | isFree x && isGround y
               -> Right $ BAct [OPIter x [o,y] "-" Det (Just$ PDBS$ infixOp "-")]
                               [(x^.mv_var, nuniv)]
         _ -> Left True

  _ | f == "-" && isGround o
    -> case is of
         [x,y] | isGround x && isFree y
               -> Right $ BAct [OPIter y [x,o] "-" Det (Just$ PDBS$ infixOp "-")]
                               [(y^.mv_var, nuniv)]
         [x,y] | isFree x && isGround y
               -> Right $ BAct [OPIter x [o,y] "+" Det (Just$ PDBS$ infixOp "+")]
                               [(x^.mv_var, nuniv)]
         _ -> Left True

  _ | MA.isJust (constants (f,length is)) -> Left True
  _ -> Left False

infixOp op _ vis = sepBy op $ mpv vis
mpv = map (pretty . (^.mv_var))

constants :: DFunctAr -> Maybe PyDopeBS
constants = go
 where
  go ("-",1)     = Just $ PDBS $ call "-"
  go ("^",2)     = Just $ PDBS $ infixOp "^"
  go ("|",2)     = Just $ PDBS $ infixOp "|"
  go ("-",2)     = Just $ PDBS $ infixOp "-"
  go ("/",2)     = Just $ PDBS $ infixOp "/"
  go ("*",2)     = Just $ PDBS $ infixOp "*"
  go ("**",2)    = Just $ PDBS $ infixOp "**"
  go ("&",2)     = Just $ PDBS $ infixOp "&"
  go ("%",2)     = Just $ PDBS $ infixOp "%"
  go ("+",2)     = Just $ PDBS $ infixOp "+"

  go ("mod",2)   = Just $ PDBS $ call "mod"
  go ("abs",1)   = Just $ PDBS $ call "abs"
  go ("log",1)   = Just $ PDBS $ call "log"
  go ("exp",1)   = Just $ PDBS $ call "exp"

  go ("<=",2)    = Just $ PDBS $ infixOp "<="
  go ("<",2)     = Just $ PDBS $ infixOp "<"
  go ("=",2)     = Just $ PDBS $ infixOp "="
  -- XXX "==" means something else in Dyna
  go ("==",2)    = Just $ PDBS $ infixOp "=="
  go (">=",2)    = Just $ PDBS $ infixOp ">="
  go (">",2)     = Just $ PDBS $ infixOp ">"
  go ("!=",2)    = Just $ PDBS $ infixOp "!="

  go ("and",2)   = Just $ PDBS $ infixOp "and"
  go ("or",2)    = Just $ PDBS $ infixOp "or"

  go ("true",0)  = Just $ PDBS $ nullary "True"
  go ("false",0) = Just $ PDBS $ nullary "False"
  go ("null",0)  = Just $ PDBS $ nullary "None"

  go ("!",1)     = Just $ PDBS $ call "not"
  go ("not",1)   = Just $ PDBS $ call "not"

  go ("eval",1)  = Just $ PDBS $ call "None;exec "
  go ("tuple",_) = Just $ PDBS $ call ""
  go _           = Nothing

  nullary v  _ _   = v
  call    fn _ vis = fn <> (parens $ sepBy "," $ mpv vis)

------------------------------------------------------------------------}}}
-- DOpAMine Printout                                                    {{{

-- | Print functor and arity based on argument list
pfas f args = dquotes $ pretty f <> "/" <> (pretty $ length args)

pfa f n = parens $ dquotes $ pretty f <> "/" <> pretty n

-- pf f vs = pretty f <> (tupled $ map pretty vs)

functorIndirect table f vs = table <> (brackets $ pfas f vs)

-- this comes up because can't assign to ()
tupledOrUnderscore vs = if length vs > 0
                         then parens ((sepBy "," $ map pretty vs) <> ",")
                         else text "_"


pslice vs = brackets $
       sepBy "," (map (\x -> if nGround (x^.mv_mi) then pretty (x^.mv_var) else ":") vs)
       <> "," -- add a comma to ensure getitem is always passed a tuple.

piterate vs = parens $
       sepBy "," (map (\x -> if nGround (x^.mv_mi) then "_" else pretty (x^.mv_var)) vs)
       <> "," -- add a comma to ensure tuple.


filterGround = map (^.mv_var) . filter (not.nGround.(^.mv_mi))

-- | Render a single dopamine opcode or its surrogate
pdope_ :: DOpAMine PyDopeBS -> State Int (Doc e)
pdope_ (OPIndr _ _)   = dynacSorry "indirect evaluation not implemented"
pdope_ (OPAsgn v val) = return $ pretty v <+> equals <+> pretty val
pdope_ (OPCheq v val) = return $ "if" <+> pretty v <+> "!="
                                      <+> pretty val <> ": continue"
pdope_ (OPCkne v val) = return $ "if" <+> pretty v <+> "=="
                                      <+> pretty val <> ": continue"
pdope_ (OPPeel vs i f _) = return $
    --"try:" `above` (indent 4 $
           tupledOrUnderscore vs
            <+> equals
                <+> "peel" <> (parens $ pfas f vs <> comma <> pretty i)
    --)
    -- you'll get a "TypeError: 'NoneType' is not iterable."
    --`above` "except (TypeError, AssertionError): continue"
pdope_ (OPWrap v vs f) = return $ pretty v
                           <+> equals
                           <+> "build"
                           <> (parens $ pfas f vs <> comma
                                <> (sepBy "," $ map pretty vs))

pdope_ (OPIter v vs f Det (Just (PDBS c))) = return $ pretty (v^.mv_var)
                                     <+> equals
                                     <+> c v vs

pdope_ (OPIter o m f _ Nothing) = do
      i <- incState
      return $ let mo = m ++ [o] in
          "for" <+> "d" <> pretty i <> "," <> piterate mo
                <+> "in" <+> functorIndirect "chart" f m <> pslice mo <> colon

    -- XXX Ought to make i and vs conditional on... doing debugging or the
    -- aggregator for this head caring.  The latter is a good bit more
    -- advanced than we are right now.
pdope_ (OPEmit h r i vs) = do
  ds <- get

  -- A python map of variable name to value
  let varmap = braces $ align $ fillPunct (comma <> space) $
         ("'nodes'" <> colon <> (encloseSep lbracket rbracket comma $ map (("d"<>).pretty) [0..ds-1]))
         : (map (\v -> let v' = pretty v in dquotes v' <> colon <+> v') vs)

  return $ "emit" <> tupled [ pretty h
                            , pretty r
                            , pretty i
                            , varmap
                            ]

-- | Render a dopamine sequence's checks and loops above a (indended) core.
pdope :: Actions PyDopeBS -> Doc e
pdope _d =         (indent 4 $ "for _ in [None]:")
           `above` (indent 8 $ evalState (go _d) 0)
 where
  go []  = return empty
  go (x:xs) = let indents = case x of OPIter _ _ _ d _ -> d /= Det ; _ -> False
              in do
                   x' <- pdope_ x
                   xs' <- go xs
                   return $ x' `above` ((if indents then indent 4 else id) xs')


printPlanHeader :: Rule -> Cost -> Maybe Int -> Doc e
printPlanHeader r c mn = do
  vcat ["'''"
       , "Span:  " <+> (prettySpanLoc $ r_span r)
       , "RuleIx:" <+> (pretty $ r_index r)
       , "EvalIx:" <+> (pretty mn)
       , "Cost:  " <+> (pretty c)
       , "'''"]

printInitializer :: Handle -> Rule -> Cost -> Actions PyDopeBS -> IO ()
printInitializer fh rule@(Rule _ h _ r _ _ ucruxes _) cost dope = do
  displayIO fh $ renderPretty 1.0 100
                 $ "@_initializers.append" -- <> (uncurry pfa $ MA.fromJust $ findHeadFA h ucruxes)
                   `above` "def" <+> char '_' <> tupled ["emit"] <> colon
                   `above` (indent 4 $ printPlanHeader rule cost Nothing)
                   `above` pdope dope
                   <> line

-- XXX INDIR EVAL
printUpdate :: Handle -> Rule -> Cost -> Int -> Maybe DFunctAr -> (DVar, DVar) -> Actions PyDopeBS -> IO ()
printUpdate fh rule@(Rule _ h _ r _ _ _ _) cost evalix (Just (f,a)) (hv,v) dope = do
  displayIO fh $ renderPretty 1.0 100
                 $ "#" <+> (pfa f a)
                   `above` "def" <+> char '_' <> tupled (map pretty [hv,v,"emit"]) <> colon
                   `above` (indent 4 $ printPlanHeader rule cost (Just evalix))
                   `above` pdope dope
                   <> line
                   <> "_updaters.append((" <> (pfa f a) <> ", _))"
                   <> line
                   <> line
                   <> line

------------------------------------------------------------------------}}}
-- Driver                                                               {{{

driver :: BackendDriver PyDopeBS
driver am um {-qm-} is pr fh = do
  -- Parser resume state
  hPutStrLn fh "parser_state = \"\"\""
  hPutStrLn fh $ show pr
  hPutStrLn fh "\"\"\""
  hPutStrLn fh ""

  -- Aggregation mapping
  forM_ (M.toList am) $ \((f,a),v) -> do
     hPutStrLn fh $ show $    "_agg_decl"
                           <> brackets (dquotes $ pretty f <> "/" <> pretty a)
                           <+> equals <+> (dquotes $ pretty v)

  hPutStrLn fh ""
  hPutStrLn fh $ "# ==Updates=="

  -- plans aggregated by functor/arity
  forM_ (M.toList um) $ \(fa, ps) -> do
     hPutStrLn fh ""
     hPutStrLn fh $ "# " ++ show fa
     forM_ ps $ \(r,n,c,vi,vo,act) -> do
       printUpdate fh r c n fa (vi,vo) act

  hPutStrLn fh ""
  hPutStrLn fh $ "# ==Initializers=="
  forM_ is $ \(r,c,a) -> do
    printInitializer fh r c a

{-
  hPutStrLn fh $ "# ==Queries=="

  forM_ (M.toList qm) $ \(fa, ps) -> do
    hPutStrLn fh $ "# " ++ show fa
    forM_ ps $ \(r,c,qv,a) -> do
      printPlanHeader fh r c
      hPutStrLn fh $ "# " ++ show qv
      -- XXX
      -- displayIO fh $ renderPretty 1.0 100 $ pdope a "XXX"
      hPutStrLn fh ""
-}

------------------------------------------------------------------------}}}
-- Export                                                               {{{

pythonBackend :: Backend
pythonBackend = Backend (Just aggrs)
                        builtins
                        (MA.isJust . constants)
                        (\o is _ _ (PDBS e) -> e o is)
                        driver

------------------------------------------------------------------------}}}
