# openvpn.pp -- create a "virtual" OpenVPN Server within a vserver
# Copyright (C) 2007 David Schmitt <david@schmitt.edv-bus.at>
# See LICENSE for the full license granted to you.

# configures the specified vserver for openvpn hosting
# see also http://oldwiki.linux-vserver.org/some_hints_from_john
# and http://linux-vserver.org/Frequently_Asked_Questions#Can_I_run_an_OpenVPN_Server_in_a_guest.3F

class virtual::openvpn::base {
	include openvpn
	module_dir { "virtual/openvpn": }
}

class virtual::openvpn::host_base inherits virtual::openvpn::base {
	file {
		"${module_dir_path}/virtual/openvpn/create_interface":
			source => "puppet://$servername/virtual/create_openvpn_interface",
			mode => 0755, owner => root, group => 0;
		"${module_dir_path}/virtual/openvpn/destroy_interface":
			source => "puppet://$servername/virtual/destroy_openvpn_interface",
			mode => 0755, owner => root, group => 0;
	}
}

define virtual::openvpn::host() {
	include openvpn::stopped
	include virtual::openvpn::host_base

	file {
		"/etc/vservers/${name}/vdir/dev/net":
			ensure => directory,
			mode => 0755, owner => root, group => root;
	}

	exec { "mktun for ${name}":
		command => "mknod -m 666 /etc/vservers/${name}/vdir/dev/net/tun c 10 200", 
		creates => "/etc/vservers/${name}/vdir/dev/net/tun",
		require => File["/etc/vservers/${name}/vdir/dev/net"];
	}
}

# this configures a specific tun interface for the given subnet
define virtual::openvpn::interface($subnet) {
	# create and setup the interface if it doesn't exist already
	# this is a "bit" coarse grained but works for me
	ifupdown::manual {
		$name:
			up => "${module_dir_path}/virtual/openvpn/create_interface ${name} ${subnet}",
			down => "${module_dir_path}/virtual/openvpn/destroy_interface ${name} ${subnet}" 
	}
}

# actually setup the openvpn server within a vserver
define virtual::openvpn::server($config) {
	include virtual::openvpn::base
	file {
		"/etc/openvpn/${name}.conf":
			ensure => present, content => $config,
			mode => 0644, owner => root, group => 0,
			require => Package["openvpn"],
			notify => Service['openvpn'];
	}
}
