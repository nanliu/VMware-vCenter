Puppet::Type.newtype(:vshield_ipset) do
  @doc = 'Manage vShield ipsets, these are used by fw rules'

  ensurable

  newparam(:name, :namevar => true) do
    desc 'ipset name'
  end

  newproperty(:value) do
    desc 'ipset value'
  end
end
