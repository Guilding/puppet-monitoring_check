# == Class: monitoring_check::server_side::install
#
#
class monitoring_check::server_side::install (
) {
  include monitoring_check::tiny_redis_install

  file { '/etc/sensu/plugins/check_server_side.rb':
    owner  => 'sensu',
    group  => 'sensu',
    mode   => '0555',
    source => 'puppet:///modules/monitoring_check/check_server_side.rb',
  }
}
