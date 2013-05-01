# Copyright (C) 2013 VMware, Inc.
import 'data.pp'

transport { 'vcenter':
  username => "${vcenter['username']}",
  password => "${vcenter['password']}",
  server   => "${vcenter['server']}",
  options  => $vcenter['options'],
}

vc_datacenter { "${dc1['path']}":
  path      => "${dc1['path']}",
  ensure    => present,
  transport => Transport['vcenter'],
}

vcenter::dvswitch{ "${dc1['path']}/dvs1":
  ensure => present,
  transport => Transport['vcenter'],

  spec => {}
}

vc_dvswitch_migrate{ "${esx3['hostname']}:${dc1['path']}/dvs1":
  vmk0 => 'dvpg-esx',
  vmnic2 => 'dvs1-uplink-pg',
  vmnic3 => 'dvs1-uplink-pg',
  transport => Transport['vcenter'],
}
