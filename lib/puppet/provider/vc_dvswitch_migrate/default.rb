# Copyright (C) 2013 VMware, Inc.

require 'pathname' # WORK_AROUND #14073 and #7788
vmware_module = Puppet::Module.find('vmware_lib', Puppet[:environment].to_s)
require File.join vmware_module.path, 'lib/puppet_x/vmware/util'
module_lib = Pathname.new(__FILE__).parent.parent.parent.parent
require File.join module_lib, 'puppet/provider/vcenter'

Puppet::Type.type(:vc_dvswitch_migrate).provide( :vc_dvswitch_migrate, 
                     :parent => Puppet::Provider::Vcenter) do
  @doc = "Manages Distributed Virtual Switch migration on an ESXi host"\
         "by moving vmknics and vmnics from standard to distributed switch"

  def vmk0 ; vmk_get 'vmk0' ; end
  def vmk1 ; vmk_get 'vmk1' ; end
  def vmk2 ; vmk_get 'vmk2' ; end
  def vmk3 ; vmk_get 'vmk3' ; end

  def vmk_get vmknic 
    pg_name = nil

    vnic = host.configManager.networkSystem.networkConfig.
      vnic.find{|v| v.device = vmknic}
    fail "#{host.name}: #{vmknic} not found" unless vnic

    pg_name =
      if (pg = vnic.portgroup) && pg != ""
        pg 
      elsif (pgKey = vnic.spec.distributedVirtualPort.portgroupKey)
        (dvpg_by_key pgKey).name
      else
        nil
      end

  end

  def vmk0= pg_name ; vmk_set 'vmk0', pg_name ; end
  def vmk1= pg_name ; vmk_set 'vmk1', pg_name ; end
  def vmk2= pg_name ; vmk_set 'vmk2', pg_name ; end
  def vmk3= pg_name ; vmk_set 'vmk3', pg_name ; end

  def vmk_set vmknic, pg_name
    pg_name_old = self.send vmknic.to_sym
    pg_new = datacenter.network.find{|pg| pg.name == pg_name}
    msg = "#{vmknic}: \"#{pg_name}\" not in portgroups of \"#{dvswitch.name}\""
    fail msg unless 
      (pg_new && pg_new.config.distributedVirtualSwitch.uuid == dvswitch.uuid)

    hostNetworkConfig.vnic <<
      RbVmomi::VIM.HostVirtualNicConfig(
        :changeOperation => 'edit',
        :device => vmknic,
        :portgroup => '',
        :spec => RbVmomi::VIM.HostVirtualNicSpec(
          :distributedVirtualPort => 
            RbVmomi::VIM.DistributedVirtualSwitchPortConnection(
              :switchUuid => dvswitch.uuid,
              :portgroupKey => pg_new.key
            )
        )
      )

    hostNetworkConfig.portgroup <<
      RbVmomi::VIM.HostPortGroupConfig(
        :changeOperation => 'remove',
        :spec => RbVmomi::VIM.HostPortGroupSpec(
          :name => pg_name_old,
          # add some properties required by wsdl
          :vlanId => -1,
          :vswitchName => '',
          :policy => RbVmomi::VIM.HostNetworkPolicy
        )
      )

    @flush_required = true
  end

  def vmnic0 ; vmnic_get 'vmnic0' ; end
  def vmnic1 ; vmnic_get 'vmnic1' ; end
  def vmnic2 ; vmnic_get 'vmnic2' ; end
  def vmnic3 ; vmnic_get 'vmnic3' ; end

  def vmnic_get vmnic
    pg_name = nil

    # There is no portgroup for uplinks on standard switch; use 
    # the switch name so the change message will make sense.
    host.configManager.networkSystem.networkConfig.
      vswitch.each do |vss|
        # bridge type determines if nicDevice is string or array
        nicDevice = Array vss.spec.bridge.nicDevice
        pg_name = vss.name if nicDevice.include? vmnic
      end

    pg_name || host.configManager.networkSystem.networkConfig.
      proxySwitch.each do |pxsw|
        pnicSpec = pxsw.spec.backing.pnicSpec.
          find{|pnic| pnic.pnicDevice == vmnic}
        pg_name = (dvpg_by_key pnicSpec.uplinkPortgroupKey).name if pnicSpec
      end

    pg_name
  end

  def vmnic0= pg_name ; vmnic_set 'vmnic0', pg_name ; end
  def vmnic1= pg_name ; vmnic_set 'vmnic1', pg_name ; end
  def vmnic2= pg_name ; vmnic_set 'vmnic2', pg_name ; end
  def vmnic3= pg_name ; vmnic_set 'vmnic3', pg_name ; end

  def vmnic_set vmnic, pg_name
    msg = "#{vmnic}: \"#{dvswitch.name}\" has no uplink "\
          "portgroup \"#{pg_name}\""
    pg = dvswitch.config.uplinkPortgroup.
        find{|ulpg|
        ulpg.name == pg_name
      } || fail msg

    hostNetworkConfig.proxySwitch[0].spec.backing.pnicSpec <<
      RbVmomi::VIM.DistributedVirtualSwitchHostMemberPnicSpec(
        :pnicDevice => vmnic,
        :uplinkPortgroupKey => pg.key
      )
    migrating_pnic << vmnic

    @flush_required = true
  end

  def flush_prep
    # remove properties from request if not changed by user
    hostNetworkConfig.props.delete :proxySwitch if 
      hostNetworkConfig.proxySwitch[0].spec.backing.pnicSpec.empty?
    hostNetworkConfig.props.delete :vnic if
      hostNetworkConfig.vnic.empty?
    hostNetworkConfig.props.delete :portgroup if
      hostNetworkConfig.portgroup.empty?

    # find standard switches from which uplinks will 
    # be removed; add the changes to the request
    if migrating_pnic.size > 0
      hostNetworkConfig.vswitch = []
      host.configManager.networkSystem.networkConfig.vswitch.each do |sw|
        if RbVmomi::VIM::HostVirtualSwitchBondBridge === sw.spec.bridge
          # standard switch for multiple uplinks
          if (sw.spec.bridge.nicDevice & migrating_pnic).size > 0
            hostNetworkConfig.vswitch << sw
            sw.changeOperation = 'edit'
            sw.spec.bridge.nicDevice -= migrating_pnic
            sw.spec.policy.nicTeaming.nicOrder.activeNic -= migrating_pnic
            sw.spec.policy.nicTeaming.nicOrder.standbyNic -= migrating_pnic
          end
        else
          # standard switch for single uplink
          if migrating_pnic.include? sw.spec.bridge.nicDevice
            fail "unexpected standard switch with simple bridge"
            # ? sw.spec.bridge.nicDevice = '' ?
          end
        end
      end
    end

    hostNetworkConfig
    # require 'ruby-debug'; debugger ; hostNetworkConfig
  end

  def flush
    return unless @flush_required
    config = flush_prep
    host.configManager.networkSystem.UpdateNetworkConfig(
      :changeMode => :modify,
      :config => config
    )
  end

  private

  def hostNetworkConfig
    @hostNetworkConfig ||=
      RbVmomi::VIM::HostNetworkConfig.new(
        :proxySwitch => [
          RbVmomi::VIM.HostProxySwitchConfig(
            :changeOperation => 'edit',
            :uuid => dvswitch.uuid,
            :spec => RbVmomi::VIM.HostProxySwitchSpec(
              # copy backing from current config so 
              # can be added to existing pnics
              :backing => proxyswitch.spec.backing
            )
          )
        ],
        :portgroup => [],
        :vnic => []
    )
  end

  def migrating_pnic
    @migrating_pnic ||= []
  end

  def host
    @host ||= 
      begin
        vim.searchIndex.FindByDnsName(
             :dnsName => resource[:host], :vmSearch => false
          ) ||
        (fail "host \"#{resource[:host]}\" not found")
      end
    @host
  end

  def proxyswitch
    # find proxyswitch corresponding to dvswitch being configured
    @proxySwitch ||= 
      begin
        dvsName = resource[:dvswitch].split('/').last
        msg = "host \"#{resource[:host]}\" is not a member of "\
          "dvswitch \"#{resource[:dvswitch]}\""
        host.configManager.networkSystem.networkInfo.proxySwitch.
          find{|pxsw| 
            pxsw.dvsName == dvsName
          } ||
        (fail msg)
      end
  end

  def datacenter
    @datacenter ||= 
      begin
        entity = host
        while entity = entity.parent
          if entity.class == RbVmomi::VIM::Datacenter
            break entity
          elsif entity == rootfolder
            fail "no datacenter found for host \"#{resource[:host]}\""
          end
        end
      end
  end

  def dvswitch
    @dvswitch ||= 
      begin
        dvsName = resource[:dvswitch].split('/').last
        datacenter.networkFolder.children.
          select{|net|
            RbVmomi::VIM::VmwareDistributedVirtualSwitch === net
          }.
          find{|net|
            net.name == dvsName
          } ||
          (fail "dvswitch \"#{resource[:dvswitch]}\"not found")
      end
  end

  def dvpg_list
    @dvpg_list ||=
      begin
        datacenter.network.select{|pg|
            RbVmomi::VIM::DistributedVirtualPortgroup === pg
          } ||
          []
      end
  end

  def dvpg_by_name name
    msg = "dvportgroup \"#{name}\" not found in dvswitch \"#{dvswitch.name}\""
    dvpg_list.find{|pg| 
        pg.config.name == name && 
          pg.config.distributedVirtualSwitch.uuid == dvswitch.uuid
      } ||
      (fail msg)
  end

  def dvpg_by_key key
    msg = "dvportgroup \"#{key}\" not found in dvswitch \"#{dvswitch.name}\""
    dvpg_list.find{|pg|
        pg.key == key &&
          pg.config.distributedVirtualSwitch.uuid == dvswitch.uuid
      } ||
      (fail msg)
  end

end
