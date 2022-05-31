> module Lec01SMTesting where

> import Control.Monad.IO.Class
> import Data.IORef
> import Test.QuickCheck
> import Test.QuickCheck.Monadic
> import Test.HUnit

State machine testing
=====================

Motivation
----------

- The combinatorics of testing:
  + $n$ features and 3-4 tests per feature         $\Longrightarrow O(n)$   test cases
  + $n$ features and testing pairs of features     $\Longrightarrow O(n^2)$ test cases
  + $n$ features and testing triples of features   $\Longrightarrow O(n^3)$ test cases
  + Race conditions? (at least two features, non-deterministic)

- A lot of work. Solution? Let the computer generate test cases, instead of
  writing them manually.

Plan
----

- Testing: "the process of using or trying something to see if it works, is
  suitable, obeys the rules, etc." -- Cambridge dictionary

- In order to check that the software under test (SUT) obeys the rules we must
  first write down the rules

- A state machine specification is one a way to formally "write down the
  rules"

- Since the state machine specification is executable (we can feed it input and
  get output), we effectively got a [test
  oracle](https://en.wikipedia.org/wiki/Test_oracle) or a [test double
  fake](https://en.wikipedia.org/wiki/Test_double) of the SUT

- Testing strategy: generate a sequence of random inputs, run it against the
  real SUT and against the fake and see if the outputs match

How it works
------------

* Test case generation:

![](./images/generator.svg){ width=400px }

* State machine testing:

![](./images/sm-testing.svg){ width=500px }

* Shrinking, when assertions fail:

![](./images/shrinking.svg){ width=400px }

* Regression testing

* Coverage
  - Risk when generating random test cases: are we generating interesting test cases?
  - How to measure coverage
  - Corner case thinking and unit tests as basis, e.g. try 0, -1, maxInt, etc


SUT
---

> newtype Counter = Counter (IORef Int)

> newCounter :: IO Counter
> newCounter = do
>   ref <- newIORef 0
>   return (Counter ref)

> incr :: Counter -> Int -> IO ()
> incr (Counter ref) i = do
>   j <- readIORef ref
>   writeIORef ref (i + j)

> get :: Counter -> IO Int
> get (Counter ref) = readIORef ref

State machine model/specification/fake
--------------------------------------

> newtype FakeCounter = FakeCounter Int
>   deriving Show

> fakeIncr :: FakeCounter -> Int -> (FakeCounter, ())
> fakeIncr (FakeCounter i) j = (FakeCounter (i + j), ())

> fakeGet :: FakeCounter -> (FakeCounter, Int)
> fakeGet (FakeCounter i) = (FakeCounter i, i)


> data Command = Incr Int | Get
>   deriving (Eq, Show)

> data Response = Unit () | Int Int
>   deriving (Eq, Show)

> type Model = FakeCounter

> initModel :: Model
> initModel = FakeCounter 0

> step :: Model -> Command -> (Model, Response)
> step m cmd = case cmd of
>   Incr i -> Unit <$> fakeIncr m i
>   Get    -> Int  <$> fakeGet m

> exec :: Counter -> Command -> IO Response
> exec c cmd = case cmd of
>   Incr i -> Unit <$> incr c i
>   Get    -> Int  <$> get c

> newtype Program = Program [Command]
>   deriving Show

> genCommand :: Gen Command
> genCommand = oneof [Incr <$> genInt, return Get]

> genInt :: Gen Int
> genInt = oneof [arbitrary] -- , elements [0, 1, maxBound, -1, minBound]] -- TODO: Fix coverage by uncommenting.

> genProgram :: Model -> Gen Program
> genProgram _m = Program <$> listOf genCommand

> samplePrograms :: IO [Program]
> samplePrograms = sample' (genProgram initModel)

> validProgram :: Model -> [Command] -> Bool
> validProgram _model _cmds = True

> shrinkCommand :: Command -> [Command]
> shrinkCommand _cmd = []

> shrinkProgram :: Program -> [Program]
> shrinkProgram _prog = [] -- Exercises.

> forallPrograms :: (Program -> Property) -> Property
> forallPrograms p =
>   forAllShrink (genProgram initModel) shrinkProgram p

> prop_counter :: Property
> prop_counter = forallPrograms $ \prog -> monadicIO $ do
>   c <- run newCounter
>   let m = initModel
>   (b, hist) <- runProgram c m prog
>   monitor (coverage hist)
>   return b

> coverage :: [(Model, Command, Response, Model)] -> Property -> Property
> coverage hist = classifyLength hist . go hist
>   where
>     go [] = id
>     go ((FakeCounter c, Incr i, _resp, _model') : hist') = classify (isOverflow c i) "overflow" . go hist'
>     go (_ : hist') = go hist'

>     isOverflow i j = toInteger i + toInteger j > toInteger (maxBound :: Int)

>     classifyLength xs = classify (length xs == 0)                    "0 length"
>                       . classify (0  < length xs && length xs <= 10) "1-10 length"
>                       . classify (10 < length xs && length xs <= 50) "10-50 length"

> runProgram :: MonadIO m => Counter -> Model -> Program -> m (Bool, [(Model, Command, Response, Model)])
> runProgram c0 m0 (Program cmds0) = go c0 m0 [] cmds0
>   where
>      go _c _m hist []           = return (True, reverse hist)
>      go  c  m hist (cmd : cmds) = do
>        resp <- liftIO (exec c cmd)
>        let (m', resp') = step m cmd
>        if resp == resp'
>        then go c m' ((m, cmd, resp, m') : hist) cmds
>        else return (False, reverse hist)

Regression tests
----------------

> assertProgram :: String -> Program -> Assertion
> assertProgram msg prog = do
>   c <- newCounter
>   let m = initModel
>   (b, _hist) <- runProgram c m prog
>   assertBool msg b

Discussion
----------

- The specification is longer than the SUT!? For something as simple as a
  counter, this is true, but for any "real world" system that e.g. persists to
  disk the model will likely be smaller by an order of magnitude or more.

- Why state machines over other forms of specifications? E.g. unit test-suite.

  + First of all, a bunch of unit tests are not a specification in the same way
    that a bunch of examples in math are not a proposition/theorem.

  + Stateless (or pure) property-based testing tries to *approximate* proof by
    induction in math. For example the following is the proposition that
    addition is associative for integers, *forall i j k. (i + j) + k == i + (j +
    k)*. It looks almost exactly like the property you'd write in a
    property-based test, but of course this test passing isn't a proof of the
    proposition, still a step in the right direction if we want to be serious
    about program correctness.

  + XXX: Stateful property-based testing using state machines, like we seen in
    this lecture, tries to approximate proof by structural induction on the
    sequence of inputs. Or inductive invariant method?!

  + Executable (as the REPL exercise shows, but also more on this later)

  + Same state machine specification can be used for concurrent testing (Lec 2)
  + Mental model

  + Already heavily used in distributed systems (later we'll see how the model
    becomes the implementation)

- Coverage?

Excerises
---------

0. If you're not comfortable with Haskell, port the above code to your favorite
   programming language.

1. Add a `Reset` `Command` which resets the counter to its initial value.

2. Implement shrinking for programs.

3. Write a REPL for the state machine. Start with the initial state, prompt the
   user for a command, apply the provided command to the step function and
   display the response as well as the new state, rinse and repeat.

   (For a SUT as simple as a counter this doesn't make much sense, but when the
   SUT get more complicated it might make sense to develope the state machine
   specification first, demo it using something like a REPL or some other simple
   UI before even starting to implement the real thing.)

4. Add a coverage check ensures that we do a `Get` after an overflow has happened.

5. Collect timing information about how long each command takes to execute on
   average.

See also
--------

- For more on how feature interaction gives rise to bugs see the following [blog
  post](https://www.hillelwayne.com/post/feature-interaction/) by Hillel Wayne
  summarising [Pamela Zave](https://en.wikipedia.org/wiki/Pamela_Zave)'s work on
  the topic;

- The original QuickCheck
  [paper](https://dl.acm.org/doi/pdf/10.1145/357766.351266) by Koen Claessen and
  John Hughes (2000) that introduced property-based testing in Haskell;

- John Hughes' Midlands Graduate School 2019
  [course](http://www.cse.chalmers.se/~rjmh/MGS2019/) on property-based testing,
  which covers the basics of state machine modelling and testing. It also
  contains a minimal implementation of a state machine testing library built on
  top of Haskell's QuickCheck;

- John Hughes' *Testing the Hard Stuff and Staying Sane*
  [talk](https://www.youtube.com/watch?v=zi0rHwfiX1Q) (2013-2014);

- Lamport's [Computation and State
  Machines](https://www.microsoft.com/en-us/research/publication/computation-state-machines/) (2008)

- "Can one generalize Turing machines so that any algorithm, never mind how ab-
  stract, can be modeled by a generalized machine very closely and faithfully?"

  Perhaps somewhat surprisingly it turns out that the answer is yes, and the
  generalisation is a state machine! (This means that in some sense the state
  machine is the ultimate model?!)

  For details see Gurevich's
  [generalisation](http://delta-apache-vm.cs.tau.ac.il/~nachumd/models/gurevich.pdf)
  of the Church-Turing thesis.

Summary
-------

Property-based testing lets us *generate unit tests* for pure
functions/components, property-based testing using state machine models lets us
generate unit tests for *stateful* functions/components.
