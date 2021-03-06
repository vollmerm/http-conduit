-- | This module implements the algorithms described in RFC 6265 for the Network.HTTP.Conduit library.
module Network.HTTP.Conduit.Cookies where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as S8
import qualified Data.ByteString.UTF8 as U
import Text.Regex
import Data.Maybe
import qualified Data.List as L
import Data.Time.Clock
import Data.Time.Calendar
import Web.Cookie
import qualified Data.CaseInsensitive as CI
import Blaze.ByteString.Builder
import qualified Network.PublicSuffixList.Lookup as PSL
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)

import qualified Network.HTTP.Conduit.Request as Req
import qualified Network.HTTP.Conduit.Response as Res
import Network.HTTP.Conduit.Types

slash :: Integral a => a
slash = 47 -- '/'

isIpAddress :: BS.ByteString -> Bool
isIpAddress a = case strs of
  Just strs' -> helper strs'
  Nothing -> False
  where s = U.toString a
        regex = mkRegex "^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$"
        strs = matchRegex regex s
        helper l = length l == 4 && all helper2 l
        helper2 v = (read v :: Int) >= 0 && (read v :: Int) < 256

-- | This corresponds to the subcomponent algorithm entitled \"Domain Matching\" detailed
-- in section 5.1.3
domainMatches :: BS.ByteString -> BS.ByteString -> Bool
domainMatches string domainString
  | string == domainString = True
  | BS.length string < BS.length domainString + 1 = False
  | domainString `BS.isSuffixOf` string && BS.singleton (BS.last difference) == U.fromString "." && not (isIpAddress string) = True
  | otherwise = False
  where difference = BS.take (BS.length string - BS.length domainString) string

-- | This corresponds to the subcomponent algorithm entitled \"Paths\" detailed
-- in section 5.1.4
defaultPath :: Req.Request m -> BS.ByteString
defaultPath req
  | BS.null uri_path = U.fromString "/"
  | BS.singleton (BS.head uri_path) /= U.fromString "/" = U.fromString "/"
  | BS.count slash uri_path <= 1 = U.fromString "/"
  | otherwise = BS.reverse $ BS.tail $ BS.dropWhile (/= slash) $ BS.reverse uri_path
  where uri_path = Req.path req

-- | This corresponds to the subcomponent algorithm entitled \"Path-Match\" detailed
-- in section 5.1.4
pathMatches :: BS.ByteString -> BS.ByteString -> Bool
pathMatches requestPath cookiePath
  | cookiePath == path' = True
  | cookiePath `BS.isPrefixOf` path' && BS.singleton (BS.last cookiePath) == U.fromString "/" = True
  | cookiePath `BS.isPrefixOf` path' && BS.singleton (BS.head remainder)  == U.fromString "/" = True
  | otherwise = False
  where remainder = BS.drop (BS.length cookiePath) requestPath
        path' = case S8.uncons requestPath of
                 Just ('/', _) -> requestPath
                 _             -> '/' `S8.cons` requestPath

createCookieJar :: [Cookie] -> CookieJar
createCookieJar = CJ

destroyCookieJar :: CookieJar -> [Cookie]
destroyCookieJar = expose

insertIntoCookieJar :: Cookie -> CookieJar -> CookieJar
insertIntoCookieJar cookie cookie_jar' = CJ $ cookie : cookie_jar
  where cookie_jar = expose cookie_jar'

removeExistingCookieFromCookieJar :: Cookie -> CookieJar -> (Maybe Cookie, CookieJar)
removeExistingCookieFromCookieJar cookie cookie_jar' = (mc, CJ lc)
  where (mc, lc) = removeExistingCookieFromCookieJarHelper cookie (expose cookie_jar')
        removeExistingCookieFromCookieJarHelper _ [] = (Nothing, [])
        removeExistingCookieFromCookieJarHelper c (c' : cs)
          | c == c' = (Just c', cs)
          | otherwise = (cookie', c' : cookie_jar'')
          where (cookie', cookie_jar'') = removeExistingCookieFromCookieJarHelper c cs

-- | Are we configured to reject cookies for domains such as \"com\"?
rejectPublicSuffixes :: Bool
rejectPublicSuffixes = True

isPublicSuffix :: BS.ByteString -> Bool
isPublicSuffix = PSL.isSuffix . decodeUtf8With lenientDecode

-- | This corresponds to the eviction algorithm described in Section 5.3 \"Storage Model\"
evictExpiredCookies :: CookieJar  -- ^ Input cookie jar
                    -> UTCTime    -- ^ Value that should be used as \"now\"
                    -> CookieJar  -- ^ Filtered cookie jar
evictExpiredCookies cookie_jar' now = CJ $ filter (\ cookie -> cookie_expiry_time cookie >= now) $ expose cookie_jar'

-- | This applies the 'computeCookieString' to a given Request
insertCookiesIntoRequest :: Req.Request m               -- ^ The request to insert into
                         -> CookieJar                   -- ^ Current cookie jar
                         -> UTCTime                     -- ^ Value that should be used as \"now\"
                         -> (Req.Request m, CookieJar)  -- ^ (Ouptut request, Updated cookie jar (last-access-time is updated))
insertCookiesIntoRequest request cookie_jar now
  | BS.null cookie_string = (request, cookie_jar')
  | otherwise = (request {Req.requestHeaders = cookie_header : purgedHeaders}, cookie_jar')
  where purgedHeaders = L.deleteBy (\ (a, _) (b, _) -> a == b) (CI.mk $ U.fromString "Cookie", BS.empty) $ Req.requestHeaders request
        (cookie_string, cookie_jar') = computeCookieString request cookie_jar now True
        cookie_header = (CI.mk $ U.fromString "Cookie", cookie_string)

-- | This corresponds to the algorithm described in Section 5.4 \"The Cookie Header\"
computeCookieString :: Req.Request m         -- ^ Input request
                    -> CookieJar             -- ^ Current cookie jar
                    -> UTCTime               -- ^ Value that should be used as \"now\"
                    -> Bool                  -- ^ Whether or not this request is coming from an \"http\" source (not javascript or anything like that)
                    -> (BS.ByteString, CookieJar)  -- ^ (Contents of a \"Cookie\" header, Updated cookie jar (last-access-time is updated))
computeCookieString request cookie_jar now is_http_api = (output_line, cookie_jar')
  where matching_cookie cookie = condition1 && condition2 && condition3 && condition4
          where condition1
                  | cookie_host_only cookie = Req.host request == cookie_domain cookie
                  | otherwise = domainMatches (Req.host request) (cookie_domain cookie)
                condition2 = pathMatches (Req.path request) (cookie_path cookie)
                condition3
                  | not (cookie_secure_only cookie) = True
                  | otherwise = Req.secure request
                condition4
                  | not (cookie_http_only cookie) = True
                  | otherwise = is_http_api
        matching_cookies = filter matching_cookie $ expose cookie_jar
        output_cookies =  map (\ c -> (cookie_name c, cookie_value c)) $ L.sort matching_cookies
        output_line = toByteString $ renderCookies $ output_cookies
        folding_function cookie_jar'' cookie = case removeExistingCookieFromCookieJar cookie cookie_jar'' of
          (Just c, cookie_jar''') -> insertIntoCookieJar (c {cookie_last_access_time = now}) cookie_jar'''
          (Nothing, cookie_jar''') -> cookie_jar'''
        cookie_jar' = foldl folding_function cookie_jar matching_cookies

-- | This applies 'receiveSetCookie' to a given Response
updateCookieJar :: Res.Response a               -- ^ Response received from server
                -> Req.Request m                -- ^ Request which generated the response
                -> UTCTime                      -- ^ Value that should be used as \"now\"
                -> CookieJar                    -- ^ Current cookie jar
                -> (CookieJar, Res.Response a)  -- ^ (Updated cookie jar with cookies from the Response, The response stripped of any \"Set-Cookie\" header)
updateCookieJar response request now cookie_jar = (cookie_jar', response {Res.responseHeaders = other_headers})
  where (set_cookie_headers, other_headers) = L.partition ((== (CI.mk $ U.fromString "Set-Cookie")) . fst) $ Res.responseHeaders response
        set_cookie_data = map snd set_cookie_headers
        set_cookies = map parseSetCookie set_cookie_data
        cookie_jar' = foldl (\ cj sc -> receiveSetCookie sc request now True cj) cookie_jar set_cookies

-- | This corresponds to the algorithm described in Section 5.3 \"Storage Model\"
-- This function consists of calling 'generateCookie' followed by 'insertCheckedCookie'.
-- Use this function if you plan to do both in a row.
-- 'generateCookie' and 'insertCheckedCookie' are only provided for more fine-grained control.
receiveSetCookie :: SetCookie      -- ^ The 'SetCookie' the cookie jar is receiving
                 -> Req.Request m  -- ^ The request that originated the response that yielded the 'SetCookie'
                 -> UTCTime        -- ^ Value that should be used as \"now\"
                 -> Bool           -- ^ Whether or not this request is coming from an \"http\" source (not javascript or anything like that)
                 -> CookieJar      -- ^ Input cookie jar to modify
                 -> CookieJar      -- ^ Updated cookie jar
receiveSetCookie set_cookie request now is_http_api cookie_jar = case (do
  cookie <- generateCookie set_cookie request now is_http_api
  return $ insertCheckedCookie cookie cookie_jar is_http_api) of
  Just cj -> cj
  Nothing -> cookie_jar

-- | Insert a cookie created by generateCookie into the cookie jar (or not if it shouldn't be allowed in)
insertCheckedCookie :: Cookie    -- ^ The 'SetCookie' the cookie jar is receiving
                    -> CookieJar -- ^ Input cookie jar to modify
                    -> Bool      -- ^ Whether or not this request is coming from an \"http\" source (not javascript or anything like that)
                    -> CookieJar -- ^ Updated (or not) cookie jar
insertCheckedCookie c cookie_jar is_http_api = case (do
  (cookie_jar', cookie') <- existanceTest c cookie_jar
  return $ insertIntoCookieJar cookie' cookie_jar') of
  Just cj -> cj
  Nothing -> cookie_jar
  where existanceTest cookie cookie_jar' = existanceTestHelper cookie $ removeExistingCookieFromCookieJar cookie cookie_jar'
        existanceTestHelper new_cookie (Just old_cookie, cookie_jar')
          | not is_http_api && cookie_http_only old_cookie = Nothing
          | otherwise = return (cookie_jar', new_cookie {cookie_creation_time = cookie_creation_time old_cookie})
        existanceTestHelper new_cookie (Nothing, cookie_jar') = return (cookie_jar', new_cookie)

-- | Turn a SetCookie into a Cookie, if it is valid
generateCookie :: SetCookie      -- ^ The 'SetCookie' we are encountering
               -> Req.Request m  -- ^ The request that originated the response that yielded the 'SetCookie'
               -> UTCTime        -- ^ Value that should be used as \"now\"
               -> Bool           -- ^ Whether or not this request is coming from an \"http\" source (not javascript or anything like that)
               -> Maybe Cookie   -- ^ The optional output cookie
generateCookie set_cookie request now is_http_api = do
          domain_sanitized <- sanitizeDomain $ step4 (setCookieDomain set_cookie)
          domain_intermediate <- step5 domain_sanitized
          (domain_final, host_only') <- step6 domain_intermediate
          http_only' <- step10
          return $ Cookie { cookie_name = setCookieName set_cookie
                          , cookie_value = setCookieValue set_cookie
                          , cookie_expiry_time = getExpiryTime (setCookieExpires set_cookie) (setCookieMaxAge set_cookie)
                          , cookie_domain = domain_final
                          , cookie_path = getPath $ setCookiePath set_cookie
                          , cookie_creation_time = now
                          , cookie_last_access_time = now
                          , cookie_persistent = getPersistent
                          , cookie_host_only = host_only'
                          , cookie_secure_only = setCookieSecure set_cookie
                          , cookie_http_only = http_only'
                          }
  where sanitizeDomain domain'
          | has_a_character && BS.singleton (BS.last domain') == U.fromString "." = Nothing
          | has_a_character && BS.singleton (BS.head domain') == U.fromString "." = Just $ BS.tail domain'
          | otherwise = Just $ domain'
          where has_a_character = not (BS.null domain')
        step4 (Just set_cookie_domain) = set_cookie_domain
        step4 Nothing = BS.empty
        step5 domain'
          | firstCondition && domain' == (Req.host request) = return BS.empty
          | firstCondition = Nothing
          | otherwise = return domain'
          where firstCondition = rejectPublicSuffixes && has_a_character && isPublicSuffix domain'
                has_a_character = not (BS.null domain')
        step6 domain'
          | firstCondition && not (domainMatches (Req.host request) domain') = Nothing
          | firstCondition = return (domain', False)
          | otherwise = return (Req.host request, True)
          where firstCondition = not $ BS.null domain'
        step10
          | not is_http_api && setCookieHttpOnly set_cookie = Nothing
          | otherwise = return $ setCookieHttpOnly set_cookie
        getExpiryTime :: Maybe UTCTime -> Maybe DiffTime -> UTCTime
        getExpiryTime _ (Just t) = (fromRational $ toRational t) `addUTCTime` now
        getExpiryTime (Just t) Nothing = t
        getExpiryTime Nothing Nothing = UTCTime (365000 `addDays` utctDay now) (secondsToDiffTime 0)
        getPath (Just p) = p
        getPath Nothing = defaultPath request
        getPersistent = isJust (setCookieExpires set_cookie) || isJust (setCookieMaxAge set_cookie)
