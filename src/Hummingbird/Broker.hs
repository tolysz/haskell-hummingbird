{-# LANGUAGE LambdaCase, FlexibleContexts #-}
module Hummingbird.Broker where

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Monad
import           Control.Exception
import           Data.Aeson
import           System.Exit
import           System.IO
import qualified System.Log.Formatter           as LOG
import qualified System.Log.Handler             as LOG hiding (setLevel)
import qualified System.Log.Handler.Simple      as LOG
import qualified System.Log.Handler.Syslog      as LOG
import qualified System.Log.Logger              as LOG

import qualified Network.MQTT.Broker            as Broker
import qualified Network.MQTT.Authentication    as Authentication
import           Network.MQTT.Authentication    (Authenticator, AuthenticatorConfig)

import           Hummingbird.Configuration
import           Hummingbird.Transport

data HummingbirdBroker auth
   = HummingbirdBroker
   { humSettingsPath :: FilePath
   , humBroker       :: Broker.Broker auth
   , humConfig       :: MVar (Config auth)
   , humTransport    :: MVar (Async ())
   }

data Status
   = Running
   | Stopped
   | StoppedWithException SomeException

withBrokerFromSettingsPath :: (Authenticator auth, FromJSON (AuthenticatorConfig auth)) => FilePath -> (HummingbirdBroker auth -> IO ()) -> IO ()
withBrokerFromSettingsPath settingsPath f = do
  -- Load the config from file.
  config <- loadConfigFromFile settingsPath >>= \case
      Left e       -> hPutStrLn stderr e >> exitFailure
      Right config -> pure config
  -- Immediately setup log handling.
  LOG.removeAllHandlers
  LOG.updateGlobalLogger LOG.rootLoggerName (LOG.setLevel $ logLevel $ logging config)
  forM_ (logAppenders $ logging config) $ \case
    SyslogAppender  -> do
      s <- LOG.openlog "hummingbird" [LOG.PID] LOG.USER LOG.DEBUG
      LOG.updateGlobalLogger LOG.rootLoggerName (LOG.addHandler s)
    ConsoleAppender -> do
      lh <- LOG.streamHandler stderr LOG.DEBUG
      let h = LOG.setFormatter lh (LOG.simpleLogFormatter "[$time : $loggername : $prio] $msg")
      LOG.updateGlobalLogger LOG.rootLoggerName (LOG.addHandler h)
  LOG.infoM "hummingbird" "Started hummingbird MQTT message broker."

  authenticator <- Authentication.newAuthenticator (auth config)
  broker <- Broker.new authenticator
  trans <- async $ runTransports broker (transports config)
  mconfig <- newMVar config
  mtransports <- newMVar trans

  f HummingbirdBroker {
     humSettingsPath = settingsPath
   , humBroker       = broker
   , humConfig       = mconfig
   , humTransport    = mtransports
   }

getConfig :: HummingbirdBroker auth -> IO (Config auth)
getConfig hum = readMVar (humConfig hum)

reloadConfig :: (FromJSON (AuthenticatorConfig auth)) => HummingbirdBroker auth -> IO (Either String (Config auth))
reloadConfig hum = modifyMVar (humConfig hum) $ \config->
  loadConfigFromFile (humSettingsPath hum) >>= \case
    Left  e -> pure (config, Left e)
    Right config' -> pure (config', Right config')

getTransportsStatus :: HummingbirdBroker auth -> IO Status
getTransportsStatus hum =
  withMVar (humTransport hum) $ poll >=> \case
    Nothing -> pure Running
    Just x  -> case x of
      Right () -> pure Stopped
      Left  e  -> pure (StoppedWithException e)

stopTransports :: HummingbirdBroker auth -> IO ()
stopTransports hum =
  withMVar (humTransport hum) cancel

startTransports :: Authenticator auth => HummingbirdBroker auth -> IO ()
startTransports hum =
  modifyMVar_ (humTransport hum) $ \asnc->
    poll asnc >>= \case
      -- Is already running. Leave as is.
      Nothing -> pure asnc
      Just _  -> do
        config <- readMVar (humConfig hum)
        async $ runTransports (humBroker hum) (transports config)