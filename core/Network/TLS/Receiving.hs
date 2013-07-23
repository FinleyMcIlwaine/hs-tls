-- |
-- Module      : Network.TLS.Receiving
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- the Receiving module contains calls related to unmarshalling packets according
-- to the TLS state
--
module Network.TLS.Receiving
    ( processHandshake
    , processPacket
    , processServerHello
    , verifyRSA
    ) where

import Control.Applicative ((<$>))
import Control.Monad.State
import Control.Monad.Error

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Network.TLS.Types (Role(..))
import Network.TLS.Util
import Network.TLS.Struct
import Network.TLS.Record
import Network.TLS.Packet
import Network.TLS.State
import Network.TLS.Handshake.State
import Network.TLS.Cipher
import Network.TLS.Crypto
import Network.TLS.Extension
import Data.X509

returnEither :: Either TLSError a -> TLSSt a
returnEither (Left err) = throwError err
returnEither (Right a)  = return a

processPacket :: Record Plaintext -> TLSSt Packet

processPacket (Record ProtocolType_AppData _ fragment) = return $ AppData $ fragmentGetBytes fragment

processPacket (Record ProtocolType_Alert _ fragment) = return . Alert =<< returnEither (decodeAlerts $ fragmentGetBytes fragment)

processPacket (Record ProtocolType_ChangeCipherSpec _ fragment) = do
    returnEither $ decodeChangeCipherSpec $ fragmentGetBytes fragment
    switchRxEncryption
    return ChangeCipherSpec

processPacket (Record ProtocolType_Handshake ver fragment) = do
    keyxchg <- gets (\st -> case stHandshake st of
                                Nothing  -> Nothing
                                Just hst -> cipherKeyExchange <$> hstPendingCipher hst)
    npn     <- getExtensionNPN
    let currentparams = CurrentParams
                        { cParamsVersion     = ver
                        , cParamsKeyXchgType = keyxchg
                        , cParamsSupportNPN  = npn
                        }
    handshakes <- returnEither (decodeHandshakes $ fragmentGetBytes fragment)
    hss <- forM handshakes $ \(ty, content) -> do
        case decodeHandshake currentparams ty content of
                Left err -> throwError err
                Right hs -> return hs
    return $ Handshake hss

processPacket (Record ProtocolType_DeprecatedHandshake _ fragment) =
    case decodeDeprecatedHandshake $ fragmentGetBytes fragment of
        Left err -> throwError err
        Right hs -> return $ Handshake [hs]

processHandshake :: Handshake -> TLSSt ()
processHandshake hs = do
    role <- isClientContext
    case hs of
        ClientHello cver ran _ _ _ ex _ -> when (role == ServerRole) $ do
            mapM_ processClientExtension ex
            startHandshakeClient cver ran
        Certificates certs            -> processCertificates role certs
        ClientKeyXchg content         -> when (role == ServerRole) $ do
            processClientKeyXchg content
        HsNextProtocolNegotiation selected_protocol ->
            when (role == ServerRole) $ setNegotiatedProtocol selected_protocol
        Finished fdata                -> processClientFinished fdata
        _                             -> return ()
    let encoded = encodeHandshake hs
    when (certVerifyHandshakeMaterial hs) $ withHandshakeM $ addHandshakeMessage encoded
    when (finishHandshakeTypeMaterial $ typeOfHandshake hs) $ withHandshakeM $ updateHandshakeDigest encoded
  where -- secure renegotiation
        processClientExtension (0xff01, content) = do
            v <- getVerifiedData True
            let bs = extensionEncode (SecureRenegotiation v Nothing)
            unless (bs `bytesEq` content) $ throwError $ Error_Protocol ("client verified data not matching: " ++ show v ++ ":" ++ show content, True, HandshakeFailure)

            setSecureRenegotiation True
        -- unknown extensions
        processClientExtension _ = return ()

decryptRSA :: ByteString -> TLSSt (Either KxError ByteString)
decryptRSA econtent = do
    ver <- getRecordState stVersion
    rsapriv <- fromJust "rsa private key" . hstRSAPrivateKey . fromJust "handshake" . stHandshake <$> get
    let cipher = if ver < TLS10 then econtent else B.drop 2 econtent
    runRecordStateSt $ do
        st <- get
        let (mmsg,rng') = withTLSRNG (stRandomGen st) (\g -> kxDecrypt g rsapriv cipher)
        put (st { stRandomGen = rng' })
        return mmsg

verifyRSA :: HashDescr -> ByteString -> ByteString -> TLSSt Bool
verifyRSA hsh econtent sign = do
    rsapriv <- fromJust "rsa client public key" . hstRSAClientPublicKey . fromJust "handshake" . stHandshake <$> get
    return $ kxVerify rsapriv hsh econtent sign

processServerHello :: Handshake -> TLSSt ()
processServerHello (ServerHello sver ran _ _ _ ex) = do
    -- FIXME notify the user to take action if the extension requested is missing
    -- secreneg <- getSecureRenegotiation
    -- when (secreneg && (isNothing $ lookup 0xff01 ex)) $ ...
    mapM_ processServerExtension ex
    withHandshakeM $ setServerRandom ran
    setVersion sver
  where processServerExtension (0xff01, content) = do
            cv <- getVerifiedData True
            sv <- getVerifiedData False
            let bs = extensionEncode (SecureRenegotiation cv $ Just sv)
            unless (bs `bytesEq` content) $ throwError $ Error_Protocol ("server secure renegotiation data not matching", True, HandshakeFailure)
            return ()

        processServerExtension _ = return ()
processServerHello _ = error "processServerHello called on wrong type"

-- process the client key exchange message. the protocol expects the initial
-- client version received in ClientHello, not the negotiated version.
-- in case the version mismatch, generate a random master secret
processClientKeyXchg :: ByteString -> TLSSt ()
processClientKeyXchg encryptedPremaster = do
    rver        <- getVersion
    role        <- isClientContext
    random      <- genRandom 48
    ePremaster  <- decryptRSA encryptedPremaster
    withHandshakeM $ do
        expectedVer <- gets hstClientVersion
        case ePremaster of
            Left _          -> setMasterSecretFromPre rver role random
            Right premaster -> case decodePreMasterSecret premaster of
                Left _                   -> setMasterSecretFromPre rver role random
                Right (ver, _)
                    | ver /= expectedVer -> setMasterSecretFromPre rver role random
                    | otherwise          -> setMasterSecretFromPre rver role premaster

processClientFinished :: FinishedData -> TLSSt ()
processClientFinished fdata = do
    cc       <- isClientContext
    expected <- getHandshakeDigest (cc == ServerRole)
    when (expected /= fdata) $ do
        throwError $ Error_Protocol("bad record mac", True, BadRecordMac)
    updateVerifiedData ServerRole fdata
    return ()

processCertificates :: Role -> CertificateChain -> TLSSt ()
processCertificates ServerRole (CertificateChain []) = return ()
processCertificates ClientRole (CertificateChain []) =
    throwError $ Error_Protocol ("server certificate missing", True, HandshakeFailure)
processCertificates role (CertificateChain (c:_))
    | role == ClientRole = withHandshakeM $ setPublicKey pubkey
    | otherwise          = withHandshakeM $ setClientPublicKey pubkey
  where pubkey = certPubKey $ getCertificate c
