{-# LANGUAGE PatternGuards, ViewPatterns, RecordWildCards, FlexibleContexts, ScopedTypeVariables #-}

{-
The matching does a fairly simple unification between the two terms, treating
any single letter variable on the left as a free variable. After the matching
we substitute, transform and check the side conditions. We also "see through"
both ($) and (.) functions on the right.

TRANSFORM PATTERNS
_eval_ - perform deep evaluation, must be used at the top of a RHS
_noParen_ - don't bracket this particular item

SIDE CONDITIONS
(&&), (||), not - boolean connectives
isAtom x - does x never need brackets
isFoo x - is the root constructor of x a "Foo"
notEq x y - are x and y not equal
notIn xs ys - are all x variables not in ys expressions
noTypeCheck, noQuickCheck - no semantics, a hint for testing only

($) AND (.)
We see through ($)/(.) by expanding it if nothing else matches.
We also see through (.) by translating rules that have (.) equivalents
to separate rules. For example:

concat (map f x) ==> concatMap f x
-- we spot both these rules can eta reduce with respect to x
concat . map f ==> concatMap f
-- we use the associativity of (.) to add
concat . map f . x ==> concatMap f . x
-- currently 36 of 169 rules have (.) equivalents

We see through (.) if the RHS is dull using id, e.g.

not (not x) ==> x
not . not ==> id
not . not . x ==> x
-}

module Hint.Match(readMatch') where

import Hint.Type (ModuleEx,Idea,idea',ideaNote,toSS')
import Util
import Timing
import qualified Data.Set as Set
import qualified Refact.Types as R

import Control.Monad
import Data.Tuple.Extra
import Data.Maybe
import Config.Type
import Data.Generics.Uniplate.Operations

import HsSyn
import SrcLoc
import BasicTypes
import RdrName
import OccName
import Data.Data
import GHC.Util

readMatch' :: [HintRule] -> Scope' -> ModuleEx -> LHsDecl GhcPs -> [Idea]
readMatch' settings = findIdeas' (concatMap readRule' settings)

readRule' :: HintRule -> [HintRule]
readRule' m@HintRule{ hintRuleGhcLHS=(stripLocs' . unwrap -> hintRuleGhcLHS)
                    , hintRuleGhcRHS=(stripLocs' . unwrap -> hintRuleGhcRHS)
                    , hintRuleGhcSide=((stripLocs' . unwrap <$>) -> hintRuleGhcSide)
                    } =
   (:) m{ hintRuleGhcLHS=wrap hintRuleGhcLHS
        , hintRuleGhcRHS=wrap hintRuleGhcRHS
        , hintRuleGhcSide=wrap <$> hintRuleGhcSide } $ do
    (l, v1) <- dotVersion' hintRuleGhcLHS
    (r, v2) <- dotVersion' hintRuleGhcRHS

    guard $ v1 == v2 && not (null l) && (length l > 1 || length r > 1) && Set.notMember v1 (Set.map occNameString (freeVars' $ maybeToList hintRuleGhcSide ++ l ++ r))
    if not (null r) then
      [ m{ hintRuleGhcLHS=wrap (dotApps' l), hintRuleGhcRHS=wrap (dotApps' r), hintRuleGhcSide=wrap <$> hintRuleGhcSide }
      , m{ hintRuleGhcLHS=wrap (dotApps' (l ++ [strToVar' v1])), hintRuleGhcRHS=wrap (dotApps' (r ++ [strToVar' v1])), hintRuleGhcSide=wrap <$> hintRuleGhcSide } ]
      else if length l > 1 then
            [ m{ hintRuleGhcLHS=wrap (dotApps' l), hintRuleGhcRHS=wrap (strToVar' "id"), hintRuleGhcSide=wrap <$> hintRuleGhcSide }
            , m{ hintRuleGhcLHS=wrap (dotApps' (l++[strToVar' v1])), hintRuleGhcRHS=wrap (strToVar' v1), hintRuleGhcSide=wrap <$> hintRuleGhcSide}]
      else []

-- Find a dot version of this rule, return the sequence of app
-- prefixes, and the var.
dotVersion' :: LHsExpr GhcPs -> [([LHsExpr GhcPs], String)]
dotVersion' (view' -> Var_' v) | isUnifyVar v = [([], v)]
dotVersion' (LL _ (HsApp _ ls rs)) = first (ls :) <$> dotVersion' (fromParen' rs)
dotVersion' (LL l (OpApp _ x op y)) =
  -- In a GHC parse tree, raw sections aren't valid application terms.
  -- To be suitable as application terms, they must be enclosed in
  -- parentheses.

  --   If a == b then
  --   x is 'a', op is '==' and y is 'b' and,
  let lSec = addParen' (cL l (SectionL noExt x op)) -- (a == )
      rSec = addParen' (cL l (SectionR noExt op y)) -- ( == b)
  in (first (lSec :) <$> dotVersion' y) ++ (first (rSec :) <$> dotVersion' x) -- [([(a ==)], b), ([(b == )], a])].
dotVersion' _ = []

---------------------------------------------------------------------
-- PERFORM THE MATCHING

findIdeas' :: [HintRule] -> Scope' -> ModuleEx -> LHsDecl GhcPs -> [Idea]
findIdeas' matches s _ decl = timed "Hint" "Match apply" $ forceList
    [ (idea' (hintRuleSeverity m) (hintRuleName m) x y [r]){ideaNote=notes}
    | decl <- findDecls' decl
    , (parent,x) <- universeParentExp' decl
    , m <- matches, Just (y, notes, subst) <- [matchIdea' s decl m parent x]
    , let r = R.Replace R.Expr (toSS' x) subst (unsafePrettyPrint $ unwrap (hintRuleGhcRHS m))
    ]

findDecls' :: LHsDecl GhcPs -> [LHsDecl GhcPs]
findDecls' x@(LL _ InstD{}) = children x
findDecls' (LL _ RuleD{}) = [] -- Often rules contain things that HLint would rewrite.
findDecls' x = [x]

matchIdea' :: Scope'
           -> LHsDecl GhcPs
           -> HintRule
           -> Maybe (Int, LHsExpr GhcPs)
           -> LHsExpr GhcPs
           -> Maybe (LHsExpr GhcPs, [Note], [(String, R.SrcSpan)])
matchIdea' sb decl HintRule{..} parent x = do
  let lhs = unwrap hintRuleGhcLHS
      rhs = unwrap hintRuleGhcRHS
      sa  = unwrap hintRuleGhcScope
      nm a b = scopeMatch' (sa, a) (sb, b)
  u <- unifyExp' nm True lhs x
  u <- validSubst' eqNoLoc' u

  -- Need to check free vars before unqualification, but after subst
  -- (with 'e') need to unqualify before substitution (with 'res').
  let e = substitute' u rhs
      res = addBracketTy' (addBracket' parent $ performSpecial' $ substitute' u $ unqualify' sa sb rhs)
  guard $ (freeVars' e Set.\\ Set.filter (not . isUnifyVar . occNameString) (freeVars' rhs)) `Set.isSubsetOf` freeVars' x
      -- Check no unexpected new free variables.

  -- Check it isn't going to get broken by QuasiQuotes as per #483. If
  -- we have lambdas we might be moving, and QuasiQuotes, we might
  -- inadvertantly break free vars because quasi quotes don't show
  -- what free vars they make use of.
  guard $ not (any isLambda' $ universe lhs) || not (any isQuasiQuote' $ universe x)

  guard $ checkSide' (unwrap <$> hintRuleGhcSide) $ ("original", x) : ("result", res) : fromSubst' u
  guard $ checkDefine' decl parent res

  return (res, hintRuleNotes, [(s, toSS' pos) | (s, pos) <- fromSubst' u, getLoc pos /= noSrcSpan])

---------------------------------------------------------------------
-- SIDE CONDITIONS

checkSide' :: Maybe (LHsExpr GhcPs) -> [(String, LHsExpr GhcPs)] -> Bool
checkSide' x bind = maybe True bool x
    where
      bool :: LHsExpr GhcPs -> Bool
      bool (LL _ (OpApp _ x op y))
        | varToStr' op == "&&" = bool x && bool y
        | varToStr' op == "||" = bool x || bool y
        | varToStr' op == "==" = expr (fromParen1' x) `eqNoLoc'` expr (fromParen1' y)
      bool (LL _ (HsApp _ x y)) | varToStr' x == "not" = not $ bool y
      bool (LL _ (HsPar _ x)) = bool x

      bool (LL _ (HsApp _ cond (sub -> y)))
        | 'i' : 's' : typ <- varToStr' cond = isType typ y
      bool (LL _ (HsApp _ (LL _ (HsApp _ cond (sub -> x))) (sub -> y)))
          | varToStr' cond == "notIn" = and [wrap (stripLocs' x) `notElem` map (wrap . stripLocs') (universe y) | x <- list x, y <- list y]
          | varToStr' cond == "notEq" = not (x `eqNoLoc'` y)
      bool x | varToStr' x == "noTypeCheck" = True
      bool x | varToStr' x == "noQuickCheck" = True
      bool x = error $ "Hint.Match.checkSide', unknown side condition: " ++ unsafePrettyPrint x

      expr :: LHsExpr GhcPs -> LHsExpr GhcPs
      expr (LL _ (HsApp _ (varToStr' -> "subst") x)) = sub $ fromParen1' x
      expr x = x

      isType "Compare" x = True -- Just a hint for proof stuff
      isType "Atom" x = isAtom' x
      isType "WHNF" x = isWHNF' x
      isType "Wildcard" x = any isFieldPun' (universeBi x) || any hasFieldsDotDot' (universeBi x)
      isType "Nat" (asInt -> Just x) | x >= 0 = True
      isType "Pos" (asInt -> Just x) | x >  0 = True
      isType "Neg" (asInt -> Just x) | x <  0 = True
      isType "NegZero" (asInt -> Just x) | x <= 0 = True
      isType "LitInt" (LL _ (HsLit _ HsInt{})) = True
      isType "LitInt" (LL _ (HsOverLit _ (OverLit _ HsIntegral{} _))) = True
      isType "Var" (LL _ HsVar{}) = True
      isType "App" (LL _ HsApp{}) = True
      isType "InfixApp" (LL _ x@OpApp{}) = True
      isType "Paren" (LL _ x@HsPar{}) = True
      isType "Tuple" (LL _ ExplicitTuple{}) = True

      isType typ (LL _ x) =
        let top = showConstr (toConstr x) in
        typ == top
      isType _ _ = False -- {-# COMPLETE LL#-}

      asInt :: LHsExpr GhcPs -> Maybe Integer
      asInt (LL _ (HsPar _ x)) = asInt x
      asInt (LL _ (NegApp _ x _)) = negate <$> asInt x
      asInt (LL _ (HsLit _ (HsInt _ (IL _ neg x)) )) = Just $ if neg then -x else x
      asInt (LL _ (HsOverLit _ (OverLit _ (HsIntegral (IL _ neg x)) _))) = Just $ if neg then -x else x
      asInt _ = Nothing

      list :: LHsExpr GhcPs -> [LHsExpr GhcPs]
      list (LL _ (ExplicitList _ _ xs)) = xs
      list x = [x]

      sub :: LHsExpr GhcPs -> LHsExpr GhcPs
      sub = transform f
        where f (view' -> Var_' x) | Just y <- lookup x bind = y
              f x = x

-- Does the result look very much like the declaration?
checkDefine' :: LHsDecl GhcPs -> Maybe (Int, LHsExpr GhcPs) -> LHsExpr GhcPs -> Bool
checkDefine' x Nothing y = declName x /= Just (varToStr' (transformBi unqual' $ head $ fromApps' y))
checkDefine' _ _ _ = True

---------------------------------------------------------------------
-- TRANSFORMATION

-- If it has '_eval_' do evaluation on it.
performSpecial' :: LHsExpr GhcPs -> LHsExpr GhcPs
performSpecial' = transform fNoParen . fEval
  where
    fEval, fNoParen :: LHsExpr GhcPs -> LHsExpr GhcPs
    fEval (LL _ (HsApp _ e x)) | varToStr' e == "_eval_" = reduce' x
    fEval x = x
    fNoParen (LL _ (HsApp _ e x)) | varToStr' e == "_noParen_" = fromParen' x
    fNoParen x = x

-- Contract : 'Data.List.foo' => 'foo' if 'Data.List' is loaded.
unqualify' :: Scope' -> Scope' -> LHsExpr GhcPs -> LHsExpr GhcPs
unqualify' from to = transformBi f
  where
    f :: Located RdrName -> Located RdrName
    f x@(L _ (Unqual s)) | isUnifyVar (occNameString s) = x
    f x = scopeMove' (from, x) to

addBracket' :: Maybe (Int, LHsExpr GhcPs) -> LHsExpr GhcPs -> LHsExpr GhcPs
addBracket' (Just (i, p)) c | needBracketOld' i p c = noLoc $ HsPar noExt c
addBracket' _ x = x

-- Type substitution e.g. 'Foo Int' for 'a' in 'Proxy a' can lead to a
-- need to bracket type applications in  This doesn't come up in HSE
-- because the pretty printer inserts them.
addBracketTy' :: LHsExpr GhcPs -> LHsExpr GhcPs
addBracketTy'= transformBi f
  where
    f :: LHsType GhcPs -> LHsType GhcPs
    f (LL _ (HsAppTy _ t x@(LL _ HsAppTy{}))) =
      noLoc (HsAppTy noExt t (noLoc (HsParTy noExt x)))
    f x = x
