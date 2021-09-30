{-# LANGUAGE DeriveDataTypeable #-}

-- |
module Swarm.Language.Location where

import Data.Data (Data)

data Location = Location {locStart :: Int, locEnd :: Int}
  deriving (Eq, Show, Data)

emptyLoc :: Location
emptyLoc = Location 0 0
