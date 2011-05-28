-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Examples.Crypto.RC4
-- Copyright   :  (c) Austin Seipp
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- An implementation of RC4 (AKA Rivest Cipher 4 or Alleged RC4/ARC4),
-- using SBV. For information on RC4, see: <http://en.wikipedia.org/wiki/RC4>.
--
-- We make no effort to optimize the code, and instead focus on a clear
-- implementation. In fact, the RC4 algorithm relies on in-place update of
-- its state heavily for efficiency, and is therefore unsuitable for a purely
-- functional implementation.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PatternGuards       #-}

module Data.SBV.Examples.Crypto.RC4 where

import Data.Char  (ord, chr)
import Data.List  (genericIndex)
import Data.Maybe (fromJust)
import Data.SBV

-----------------------------------------------------------------------------
-- * Types
-----------------------------------------------------------------------------

-- | RC4 State contains 256 8-bit values. We use a tree structure
-- to represent the state since RC4 needs access to the array via
-- a symbolic index and it's important to minimize access time.
data S = SLeaf SWord8
       | SBin  S S
       deriving Show

instance Mergeable S where
  symbolicMerge b (SLeaf i)  (SLeaf j)    = SLeaf (ite b i j)
  symbolicMerge b (SBin l r) (SBin l' r') = SBin  (ite b l l') (ite b r r')
  symbolicMerge _ _          _            = error $ "RC4.symbolicMerge: Impossible happened while merging states"

-- | Reading a value. We bit-blast the index and descend down the full tree
-- according to bit-values.
readS :: S -> SWord8 -> SWord8
readS s i = walk (blastBE i) s
  where walk []     (SLeaf v)  = v
        walk (b:bs) (SBin l r) = ite b (walk bs r) (walk bs l)
        walk _      _          = error $ "RC4.readS: Impossible happened while reading: " ++ show i

-- | Writing a value. Similar to how reads are done. The important thing is that the tree
-- representation keeps updates to a minimum.
writeS :: S -> SWord8 -> SWord8 -> S
writeS s i j = walk (blastBE i) s
  where walk []     _          = SLeaf j
        walk (b:bs) (SBin l r) = ite b (SBin l (walk bs r)) (SBin (walk bs l) r)
        walk _      _          = error $ "RC4.writeS: Impossible happened while reading: " ++ show i

-- | Construct the fully balanced initial tree, where the leaves are simply the numbers @0@ through @255@.
initS :: S
initS = mkTree [SLeaf i | i <- [0 .. 255]]
  where mkTree []  = error $ "RC4: initS: Impossible happened"
        mkTree [l] = l
        mkTree ns  = let (l, r) = splitAt (length ns `div` 2) ns in SBin (mkTree l) (mkTree r)

-- | The key is a stream of 'Word8' values.
type Key = [SWord8]

-- | Represents the current state of the RC4 stream: it is the @S@ array
-- along with the @i@ and @j@ index values used by the PRGA.
type RC4 = (S, SWord8, SWord8)

-----------------------------------------------------------------------------
-- * The PRGA
-----------------------------------------------------------------------------

-- | Swaps two elements in the RC4 array.
swap :: SWord8 -> SWord8 -> S -> S
swap i j st = writeS (writeS st i stj) j sti
  where sti = readS st i
        stj = readS st j

-- | Implements the PRGA used in RC4. We return the new state and the next key value generated.
prga :: RC4 -> (SWord8, RC4)
prga (st', i', j') = (readS st kInd, (st, i, j))
  where i    = i' + 1
        j    = j' + readS st' i
        st   = swap i j st'
        kInd = readS st i + readS st j

-----------------------------------------------------------------------------
-- * Key schedule
-----------------------------------------------------------------------------

-- | Constructs the state to be used by the PRGA using the given key.
initRC4 :: Key -> S
initRC4 key
 | keyLength < 1 || keyLength > 256
 = error $ "RC4 requires a key of length between 1 and 256, received: " ++ show keyLength
 | True
 = snd $ foldl mix (0, initS) [0..255]
 where keyLength = length key
       mix :: (SWord8, S) -> SWord8 -> (SWord8, S)
       mix (j', s) i = let j = j' + readS s i + genericIndex key (fromJust (unliteral i) `mod` fromIntegral keyLength)
                       in (j, swap i j s)

-- | The key-schedule. Note that this function returns an infinite list.
keySchedule :: Key -> [SWord8]
keySchedule key = genKeys (initRC4 key, 0, 0)
  where genKeys :: RC4 -> [SWord8]
        genKeys st = let (k, st') = prga st in k : genKeys st'

-- | Generate a key-schedule from a given key-string.
keyScheduleString :: String -> [SWord8]
keyScheduleString = keySchedule . map (literal . fromIntegral . ord)

-----------------------------------------------------------------------------
-- * Encryption and Decryption
-----------------------------------------------------------------------------

-- | RC4 encryption. We generate key-words and xor it with the input. The
-- following test-vectors are from Wikipedia <http://en.wikipedia.org/wiki/RC4>:
--
-- >>> concatMap hex $ encrypt "Key" "Plaintext"
-- "bbf316e8d940af0ad3"
--
-- >>> concatMap hex $ encrypt "Wiki" "pedia"
-- "1021bf0420"
--
-- >>> concatMap hex $ encrypt "Secret" "Attack at dawn"
-- "45a01f645fc35b383552544b9bf5"
encrypt :: String -> String -> [SWord8]
encrypt key pt = zipWith xor (keyScheduleString key) (map cvt pt)
  where cvt = literal . fromIntegral . ord

-- | RC4 decryption. Essentially the same as decryption. For the above test vectors we have:
--
-- >>> decrypt "Key" [0xbb, 0xf3, 0x16, 0xe8, 0xd9, 0x40, 0xaf, 0x0a, 0xd3]
-- "Plaintext"
--
-- >>> decrypt "Wiki" [0x10, 0x21, 0xbf, 0x04, 0x20]
-- "pedia"
--
-- >>> decrypt "Secret" [0x45, 0xa0, 0x1f, 0x64, 0x5f, 0xc3, 0x5b, 0x38, 0x35, 0x52, 0x54, 0x4b, 0x9b, 0xf5]
-- "Attack at dawn"
decrypt :: String -> [SWord8] -> String
decrypt key ct = map cvt $ zipWith xor (keyScheduleString key) ct
  where cvt = chr . fromIntegral . fromJust . unliteral

-----------------------------------------------------------------------------
-- * Verification
-----------------------------------------------------------------------------

-- | Prove that round-trip encryption/decryption leaves the plain-text unchanged.
-- The theorem is stated parametrically over key and plain-text sizes. The expression
-- performs the proof for a 40-bit key (5 bytes) and 40-bit plaintext (again 5 bytes).
--
-- Note that this theorem is trivial to prove, since it is essentially establishing
-- xor'in the same value twice leaves a word unchanged (i.e., @x `xor` y `xor` y = x@).
-- However, the proof takes quite a while to complete, as it gives rise to a fairly
-- large symbolic trace.
rc4IsCorrect :: IO ThmResult
rc4IsCorrect = prove $ do
        key <- mkFreeVars 5
        pt  <- mkFreeVars 5
        let ks  = keySchedule key
            ct  = zipWith xor ks pt
            pt' = zipWith xor ks ct
        return $ pt .== pt'
