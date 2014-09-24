# == Define: monitoring_check
#
# A define for managing monitoring checks - wraps sensu::check giving
# less bolierplate and yelp specific runbook functionality.
#
# === Parameters
#
# [*ensure*]
# present or absent, defaults to present
#
# [*command*]
# The name of the check command to run, this should be a standard nagios/sensu type check
#
# [*needs_sudo*]
# Boolean for if to run this check with sudo. Defaults to false
#
# [*sudo_user*]
# The user to sudo to (if needs_sudo is true). Defaults to root
#
# [*check_every*]
# How often to run this check. Can be an integer number of seconds, or an
# abbreviation such as '2m' for 120 seconds, or '2h' for 7200 seconds.
# Defaults to 5m
#
# [*alert_after*]
# How long a check is allowed to be failing for before alerting (pagerduty/irc).
# Can be an integer number of seconds, or an abbreviattion
# Defaults to undef, meaning sensu will alert as soon as the check fails.
#
# [*realert_every*]
# Number of event occurrences before the handler should take action.
# For example, 10, would mean only re-notify every 10 fails.
# This logic only occurs after the alert_after time has expired.
# Defaults to -1 which means sensu will use exponential backoff.
#
# [*runbook*]
# The URI to the google doc runbook for this check
# Should be of the form: y/my_runbook_name (preferred), or
# http://...some.uri
#
# [*tip*]
# A quick tip for how to respond to / clear the alert without having to read the
# runbook. Optional (and custom checks are recommended to put the tip into the
# check output).
#
# [*annotation*]
# The line of code that should be referenced as the "originator" for this
# monitoring check.  Obviously there is an entire call stack to choose from.
# Try to use the most relevant/helpful value here.
#
# [*sla*]
#  Allows you to define the SLA for the service you are monitoring. Notice
#  it is lower case!
#  
#  This is (currently) just a human readable string to give more context
#  about the urgency of an alert when you see it in a ticket/page/email/irc.
#
# [*team*]
# The team responsible for this check (i.e. which team's pagerduty to escalate to)
# Defaults to operations, allowed to be any team in the hiera _sensu::teams_ key.
#
# [*page*]
# Boolean. If this alert should be escalated through to pagerduty.
# Every page also goes to a mandatory ${team}-pages, and is not configurable.
# Defaults to false.
#
# [*irc_channels*]
# Array of IRC channels to send notfications to. Set this to multiple channels
# if other teams are interested in your notifications. Set to [] if you need
# no IRC notifcations. (like, motd only or page only)
# Defaults to nil, which uses ${team}-notifications default from the irc handler.
#
# [*notification_email*]
# A string for the mailto for emails for alerts. (paging and non-paging)
# Defaults to undef, which makes the handler use the global team default.
# Use false if you want the alert to never send emails.
# It *can* take a comma separated list as an argument like a normal email mailto.
#
# [*ticket*]
# Boolean. Determines if the JIRA handler is executed or not. Defaults to false.
#
# [*project*]
# Optionally set the JIRA project for a check. Otherwise if, if ticket=>true, then
# it will use the project set for the team.
#
# [*dependencies*]
# A list of dependencies for this check to be escalated if it's critical.
# If any of these dependencies are critical then the check will not be escalated
# by the handler
#
# Dependencies are simply other check names, or certname/checkname for
# checks on other hosts
#
# Defaults to empty
#
# [*high_flap_threshold*]
# Custom threshold to consider this service flapping at
# Defaults to unset
#
# [*low_flap_threshold*]
# Custom threshold at which to consider this services as having stopped flapping.
# Defaults to unset
# See http://nagios.sourceforge.net/docs/3_0/flapping.html for more details
#
# [*aggregate*]
# Boolean that configures the check to not be handled, and instead go to the
# aggregates api, which is used for "cluster" checks. Notification parameters
# have no effect, as handle:false for these.
#
# [*sensu_custom*]
# A hash of custom parameters to inject into the sensu check JSON output.
# These will override any parameters configured by the wrapper.
# Defaults to an empty hash.
#
define monitoring_check (
    $command,
    $runbook,
    $annotation            = annotate(),
    $check_every           = '1m',
    $alert_after           = '0s',
    $realert_every         = '-1',
    $irc_channels          = undef,
    $notification_email    = 'undef',
    $ticket                = false,
    $project               = false,
    $tip                   = false,
    $sla                   = 'No SLA defined.',
    $page                  = false,
    $needs_sudo            = false,
    $sudo_user             = 'root',
    $team                  = 'operations',
    $ensure                = 'present',
    $dependencies          = [],
    $use_sensu             = true,
    $use_nagios            = false,
    $nagios_custom         = {},
    $low_flap_threshold    = undef,
    $high_flap_threshold   = undef,
    $aggregate             = false,
    $sensu_custom          = {},
) {

  # Catch RE errors before they stop sensu:
  # https://github.com/sensu/sensu/blob/master/lib/sensu/settings.rb#L215
  validate_re($name, '^[\w\.-]+$', "Your sensu check name has special chars sensu won't like: ${name}" )

  # Pull the team data configuration from the sensu_handlers module in order
  # to validate the given inputs.
  $team_data = hiera('sensu_handlers::teams', {})

  validate_re($ensure, '^(present|absent)$')
  validate_string($command)
  validate_string($runbook)
  validate_re($runbook, '^(https?://|y/)')
  validate_string($team)
  if size(keys($team_data)) == 0 {
    fail("No sensu_handlers::teams data could be loaded - need at least 1 team")
  }
  $team_names = join(keys($team_data), '|')
  validate_re($team, "^(${team_names})$")
  validate_bool($ticket)

  validate_bool($aggregate)
  # Make $handle be the inverse of aggregate.
  # If we are aggregate, we do not handle them.
  $handle = $aggregate ? { true => false, false => true }

  validate_hash($sensu_custom)
  validate_hash($nagios_custom)

  $interval_s = human_time_to_seconds($check_every)
  validate_re($interval_s, '^\d+$')
  $alert_after_s = human_time_to_seconds($alert_after)
  validate_re($alert_after_s, '^\d+$')
  validate_re($realert_every, '^(-)?\d+$')

  if $irc_channels != undef {
    $irc_channel_array = any2array($irc_channels)
  } else {
    $team_hash = $team_data
    $irc_channel_array = $team_hash[$team]['notifications_irc_channel']
  }

  if str2bool($needs_sudo) {
    validate_re($command, '^/.*', "Your command, ${command}, must use a full path if you are going to use sudo")
    $real_command = "sudo -H -u ${sudo_user} -- ${command}"
    $cmd = regsubst($command, '^(\S+).*','\1') # Strip the options off, leaving just the check script
    if str2bool($use_sensu) {
      sudo::conf { "sensu_${title}":
        priority => 10,
        content  => "sensu       ALL=(${sudo_user}) NOPASSWD: ${cmd}\nDefaults!${cmd} !requiretty",
      } ->
      Sensu::Check[$name]
    }
  }
  else {
    $real_command = $command
  }

  if str2bool($use_sensu) {
    sensu::check { $name:
      ensure              => $ensure,
      handlers            => 'default', # Always use the default handler, it'll route things via escalation_team
      command             => $real_command,
      interval            => $interval_s,
      low_flap_threshold  => $high_flap_threshold,
      high_flap_threshold => $low_flap_threshold,
      handle              => $handle,
      aggregate           => $aggregate,
      custom              => merge({
        alert_after           => $alert_after_s,
        realert_every         => $realert_every,
        runbook               => $runbook,
        annotation            => $annotation,
        sla                   => $sla,
        dependencies          => any2array($dependencies),
        team                  => $team,
        irc_channels          => $irc_channel_array,
        notification_email    => $notification_email,
        ticket                => $ticket,
        project               => $project,
        page                  => str2bool($page),
        tip                   => $tip,
      }, $sensu_custom)
    }
  }
  if str2bool($use_nagios) {
    fail("Nagios check generation unimplemented for check ${title}")
  }
}

