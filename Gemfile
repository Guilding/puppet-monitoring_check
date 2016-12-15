source "https://rubygems.org"

group :development do
  gem "pry"
  gem "pry-byebug"
  gem 'simplecov', :require => false, :group => :test
  gem "puppet-blacksmith"
end

group :test do
  gem "json", '~> 1.8.3'
  gem "json_pure", '~> 1.8.3'
  # Pin for 1.8.7 compatibility for now
  gem "rake", '< 11.0.0'
  gem "puppet", ENV['PUPPET_VERSION'] || '~> 3.7.0'
  gem "puppet-lint"

  # Pin for 1.8.7 compatibility for now
  gem "rspec", '< 3.2.0'
  gem "rspec-core", "3.1.7"
  gem "rspec-puppet", "~> 2.1"
  gem "rspec-puppet-utils"

  gem "puppet-syntax"
  gem "puppetlabs_spec_helper"
  gem "hiera"
  gem 'hiera-puppet-helper',
    :git => 'https://github.com/bobtfish/hiera-puppet-helper.git',
    :ref => '5ed989a130bc62cc6bdb923596586284f0bd73df'
end
