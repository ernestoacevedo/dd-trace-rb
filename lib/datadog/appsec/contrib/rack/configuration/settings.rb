# typed: false

require 'datadog/appsec/contrib/configuration/settings'
require 'datadog/appsec/contrib/rack/ext'

module Datadog
  module AppSec
    module Contrib
      module Rack
        module Configuration
          # Custom settings for the Rack integration
          class Settings < Datadog::AppSec::Contrib::Configuration::Settings
            option :enabled do |o|
              o.default { env_to_bool(Ext::ENV_ENABLED, true) }
              o.lazy
            end
          end
        end
      end
    end
  end
end
