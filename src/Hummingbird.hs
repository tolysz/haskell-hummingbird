{-# LANGUAGE ExplicitForAll      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
module Hummingbird ( run ) where
--------------------------------------------------------------------------------
-- |
-- Module      :  Hummingbird
-- Copyright   :  (c) Lars Petersen 2017
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------

import           Data.Aeson
import           Data.Proxy
import           Data.Version
import           Options

import           Network.MQTT.Broker.Authentication (Authenticator,
                                                     AuthenticatorConfig)

import qualified Hummingbird.Administration.Server  as Administration
import qualified Hummingbird.Configuration          as Config
import qualified Hummingbird.Internal               as Hummingbird

newtype MainOptions = MainOptions
  { mainSettingsFilePath :: FilePath }

instance Options MainOptions where
  defineOptions = MainOptions
    <$> simpleOption "settings" "/etc/hummingbird/settings.yml" "Path to the .yml settings file"

run :: forall auth. (Authenticator auth, FromJSON (AuthenticatorConfig auth)) => Version -> Proxy (Config.Config auth) -> IO ()
run version _ =
  runCommand $ \mainOpts _args-> do
    hum <- Hummingbird.new version ( mainSettingsFilePath mainOpts ) :: IO (Hummingbird.Hummingbird auth)
    Hummingbird.start hum
    Administration.run hum
