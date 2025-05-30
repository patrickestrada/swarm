/**
Uses a string to maintain a queue of coordinates.
*/

def λmatch = \f. \p. match p f end

def coordsToString : (Int * Int) -> Text = λmatch \x. \y.
  format x ++ "," ++ format y
  end

def indexOfRec : Int -> Text -> Text -> (Unit + Int) = \pos. \inputString. \targetChar.
  if (pos >= chars inputString) {
    inL ()
  } {
    if (toChar (charAt pos inputString) == targetChar) {
      inR pos
    } {
      indexOfRec (pos + 1) inputString targetChar
    }
  }
  end

def indexOf : Text -> Text -> (Unit + Int) =
  indexOfRec 0
  end

// Drops the first character of a string
def strTail : Text -> Text = \inputString.
  match (split 1 inputString) \_. \rest. rest
  end

def splitOnFirstChar : Text -> Text -> (Text * Text) = \inputString. \splitChar.
  case (indexOf inputString splitChar)
    (\_.
      // Did not find the split character, so return the original string
      (inputString, "")
    )
    (\foundIdx.
      match (split foundIdx inputString) \a. \b.
      (a, strTail b)
    )
  end

def getDecimalCharValue = \inputString. \idx.
  charAt idx inputString - charAt 0 "0"
  end

// Works from right to left
def parseDecimalRec : Int -> Text -> Int = \charsRemaining. \inputString.
  if (charsRemaining > 0) {
    getDecimalCharValue inputString (charsRemaining - 1) + 10 * parseDecimalRec (charsRemaining - 1) inputString
  } {0}
  end

def parseDecimal : Text -> Int = \inputString.
  let isNegative = toChar (charAt 0 inputString) == "-" in
  let negationMultiplier = if isNegative {-1} {1} in
  let modifiedString = if isNegative {strTail inputString} {inputString} in
  let stringLength = chars modifiedString in
  negationMultiplier * parseDecimalRec stringLength modifiedString;
  end

// Comma (",") is the separator between abscissa and ordinate
def stringToCoords : Text -> (Int * Int) = \coordsString.
  match (splitOnFirstChar coordsString ",") \a. \b.
  (parseDecimal a, parseDecimal b)
  end

// APPEND to string representation of a coordinate list
def snoc : (Int * Int) -> Text -> Text = \coords. \strList.
  let delimiter = if (chars strList > 0) {";"} {""} in
  strList ++ delimiter ++ coordsToString coords;
  end

// Extracts the first element and returns the shortened list
def pop : Text -> (Unit + ((Int * Int) * Text)) = \strList.
  if (chars strList > 0) {
    let pair = splitOnFirstChar strList ";" in
    match pair \a. \b.
    inR (stringToCoords a, b)
  } {
    inL ();
  }
  end

def getDir = \dest.
    path (inL ()) (inL dest);
    end;

def doAtLoc = \currLoc. \targetLoc. \func.
  teleport self targetLoc;
  x <- func;
  teleport self currLoc;
  pure x;
  end;

def moveTail = \tailList.
  emptyHere <- isempty;
  if emptyHere {
    let maybeShifted = pop tailList in
    case maybeShifted (\_.
      // Nothing to pick up or replace
      pure tailList;

    ) (λmatch \farthestTail. \newInit.
        newLoc <- whereami;
        grabbedItem <- doAtLoc newLoc farthestTail grab;
        place grabbedItem;

        pure $ snoc newLoc newInit;
    );
  } {
    pure tailList;
  }
  end;

def moveOneStep = \tailList.

    // This robot will always be sitting atop the apple
    r <- robotnamed "spawn";
    targetLoc <- as r {whereami};

    maybeD <- getDir targetLoc;
    case maybeD (\_. say "Dead!"; pure "") (λmatch \dir. \_.
      turn dir;
      newList <- moveTail tailList;
      move;
      pure newList
    );
    end

// Invariant: No tail pieces shall ever be moved underneath the
// snake robot, unless an apple was just picked up.
def moveToApple = \tailList.

  myLoc <- whereami;

  appleHere <- ishere "apple";
  if appleHere {

    modifiedTailList <- try {
      make "tail";
      swap "tail";
      pure $ snoc myLoc tailList;
    } {
      grab;
      pure tailList;
    };
    // Need to move here so that we get out of the way
    // if the tail gets elongated
    moveOneStep modifiedTailList;
  } {
    moveOneStep tailList;
  }
  end;

def go = \tailList.
  newList <- instant $ moveToApple tailList;
  go newList;
  end;

go "";
