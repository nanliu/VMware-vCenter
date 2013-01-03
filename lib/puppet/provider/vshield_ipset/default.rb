require 'puppet/provider/vshield'

Puppet::Type.type(:vshield_ipset).provide(:default, :parent => Puppet::Provider::Vshield) do
  @doc = 'Manages vShield ipset.'

  def exists?
    true
  end

  def destroy
    # not implemented
  end

  def value
    # not implemented
  end

  def value=(value)
    Puppet.debug("Updating to #{value}")
  end
end
