# virtual/vserver.pp -- manage vserver specifica
# Copyright (C) 2007 David Schmitt <david@schmitt.edv-bus.at>
# See LICENSE for the full license granted to you.

module_dir{ "virtual/contexts": }

class vserver::host {

	package { [ 'util-vserver', debootstrap ]: ensure => installed, }

	file {
		"/usr/local/bin/build_vserver":
			source => "puppet:///modules/virtual/build_vserver",
			mode => 0755, owner => root, group => root,
			require => [ Package['util-vserver'], Package[debootstrap],
				# this comes from dbp module and is the most current puppet deb
				File["${module_dir_path}/dbp/puppet_current.deb"] ];
		"/etc/vservers/local-interfaces":
			ensure => directory,
			mode => 0755, owner => root, group => root;
		"/etc/cron.daily/vserver-hashify":
			source => "puppet:///modules/virtual/hashify.cron.daily",
			mode => 0755, owner => root, group => root;
		"/var/lib/vservers/.hash":
			ensure => directory,
			mode => 0700, owner => root, group => root,
			require => Package["util-vserver"];
		"/etc/vservers/.defaults/apps/vunify/hash/root":
			ensure => link,
			target => "/var/lib/vservers/.hash",
			owner => root, group => root,
			require => Package["util-vserver"];
	}

	# linux-image-2.6.18-6-vserver-amd64 2.6.18.dfsg.1-22etch2 doesn't have COWBL enabled
	# therefore hashifying all vservers is a very bad idea
	case $operatingsystem {
		Debian,debian: {
			case $lsbdistcodename {
				# disabled lenny, just to be on the safe side
				etch,lenny: {
					case $architecture {
						amd64: {
							File["/etc/cron.daily/vserver-hashify"]{ ensure => absent }
						}
					}
				}
			}
		}
	}
}

define vs_create($in_domain, $context, $legacy = false, $distribution = 'lenny') { 
	$vs_name = $legacy ? { true => $name, false => $in_domain ? { '' => $name, default => "${name}.${in_domain}" } }

	case $vs_name { '': { fail ( "Cannot create VServer with empty name" ) } }

	case $legacy {
		true: {
			exec { "/bin/false # cannot create legacy vserver ${vs_name}":
				creates => "/etc/vservers/${vs_name}",
				alias => "vs_create_${vs_name}"
			}
		}
		false: {
			exec { "/usr/local/bin/build_vserver \"${vs_name}\" ${context} ${distribution}":
				creates => "/etc/vservers/${vs_name}",
				require => File["/usr/local/bin/build_vserver"],
				alias => "vs_create_${vs_name}"
			}
		}
	}
}
		

# ensure: present, stopped, running
define vserver($ensure, $context, $distribution = 'lenny', $in_domain = '', $mark = '', $legacy = false, $additional_mounts = '') {
	case $in_domain { '': {} 
		default: { err("${fqdn}: vserver ${name} uses deprecated \$in_domain" ) }
	}
	$vs_name = $legacy ? { true => $name, false => $in_domain ? { '' => $name, default => "${name}.${in_domain}" } }
	case $vs_name { '': { fail ( "Cannot create VServer with empty name" ) } }

	$if_dir = "/etc/vservers/${vs_name}/interfaces"
	$mark_file = "/etc/vservers/${vs_name}/apps/init/mark"

	$vs_name_underscores = gsub($vs_name, '\.', '_')
	$cron_job = "/etc/cron.daily/puppet-vserver-${vs_name_underscores}"

	case $ensure {
		present,running,stopped: { vs_create{$name: in_domain => $in_domain, context => $context, legacy => $legacy, distribution => $distribution } }
	}

	file {
		$if_dir:
			ensure => directory, checksum => mtime,
			require => Exec["vs_create_${vs_name}"];
		$cron_job:
			content => template("virtual/cron.hourly.vserver"),
			mode => 0755, owner => root, group => root;
	}

	$default_mounts = template("virtual/vserver_fstab")
	config_file {
		"/etc/vservers/${vs_name}/fstab":
			content => "${default_mounts}${additional_mounts}\n",
			notify => Exec["vs_restart_${vs_name}"],
			require => Exec["vs_create_${vs_name}"];
		"/etc/vservers/${vs_name}/context":
			content => "${context}\n",
			notify => Exec["vs_restart_${vs_name}"],
			require => Exec["vs_create_${vs_name}"];
		# create illegal configuration, when two vservers have the same context
		# number
		"${module_dir_path}/virtual/contexts/${context}":
			content => "\n";
		"/etc/vservers/${vs_name}/uts/nodename":
			content => "${vs_name}\n",
			notify => Exec["vs_restart_${vs_name}"],
			require => Exec["vs_create_${vs_name}"];
		"/etc/vservers/${vs_name}/name":
			content => "${vs_name}\n",
			# Changing this needs no restart
			# notify => Exec["vs_restart_${vs_name}"],
			require => Exec["vs_create_${vs_name}"];
	}

	file {
		"/etc/vservers/${vs_name}/apps/vunify":
			ensure => directory,
			require => Exec["vs_create_${vs_name}"]
	}

	case $ensure {
		stopped: {
			exec { "vserver ${vs_name} stop":
				onlyif => "test -e \$(readlink -f /etc/vservers/${vs_name}/run || echo /doesntexist )",
				require => Exec["vs_create_${vs_name}"],
				# fake the restart exec in the stopped case, so the dependencies are fulfilled
				alias => "vs_restart_${vs_name}",
			}
			file { $mark_file: ensure => absent, }
		}
		running: {
			exec { "vserver ${vs_name} start":
				unless => "test -e \$(readlink -f /etc/vservers/${vs_name}/run)",
				require => [ Exec["vs_create_${vs_name}"], File["/etc/vservers/${vs_name}/context"] ]
			}

			exec { "vserver ${vs_name} restart":
				refreshonly => true,
				require => Exec["vs_create_${vs_name}"],
				alias => "vs_restart_${vs_name}",
				subscribe => File[$if_dir],
			}

			case $mark {
				'': {
					err("${fqdn}: vserver ${vs_name} set to running, but won't be started on reboot without mark!")
					file { $mark_file: ensure => absent, }
				}
				default: { 
					config_file { "/etc/vservers/${vs_name}/apps/init/mark":
						content => "${mark}\n",
						require => Exec["vs_create_${vs_name}"],
					}
				}
			}
		}
	}

}

# Changeing stuff with this define won't do much good, since it relies on
# restarting the vservers to do the work, which won't clean up orphaned
# interfaces
define vs_interface($prefix = 24, $dev = '') {

	file {
		"/etc/vservers/local-interfaces/${name}":
			ensure => directory,
			mode => 0755, owner => root, group => root;
		"/etc/vservers/local-interfaces/${name}/ip":
			content => "${name}\n",
			mode => 0644, owner => root, group => root;
		"/etc/vservers/local-interfaces/${name}/prefix":
			content => "${prefix}\n",
			mode => 0644, owner => root, group => root;
	}

	case $dev {
		'': {
			file { 
				"/etc/vservers/local-interfaces/${name}/nodev":
					ensure => present,
					mode => 0644, owner => root, group => root;
				"/etc/vservers/local-interfaces/${name}/dev":
					ensure => absent;
			}
		}
		default: {
			config_file { "/etc/vservers/local-interfaces/${name}/dev": content => "${dev}\n", }
			file { "/etc/vservers/local-interfaces/${name}/nodev": ensure => absent, }
		}
	}
}

define vs_ip($vserver, $ip, $ensure) {
	err("$fqdn is using deprecated vs_ip instead of vs_ip_binding for $name")
	vs_ip_binding { $name: vserver => $vserver, ip => $ip, ensure => $ensure }
}

define vs_ip_binding($vserver, $ip, $ensure) {
	case $ensure {
		connected: {
			file { "/etc/vservers/${vserver}/interfaces/${name}":
				ensure => "/etc/vservers/local-interfaces/${ip}/",
				require => [ File["/etc/vservers/local-interfaces/${ip}"], Exec["vs_create_${vserver}"] ],
				notify => Exec["vs_restart_${vserver}"],
			}
		}
		disconnected: {
			file { "/etc/vservers/${vserver}/interfaces/${name}":
				ensure => absent,
				# TODO: fix message:
				# warning: //ic/vs_ip[mailman_00]/File[/etc/vservers/mailman/interfaces/mailman_00]: Exec[vserver mailman restart] still depend on me -- not deleting
				# notify => Exec["vs_restart_${vserver}"],
			}
		}
		default: {
			err( "${fqdn}: vs_ip: ${vserver} -> ${ip}: unknown ensure: '${ensure}'" )
		}
	}
}
