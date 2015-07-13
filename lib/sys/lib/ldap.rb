# encoding: utf-8
class Sys::Lib::Ldap
  attr_accessor :connection
  attr_accessor :host
  attr_accessor :port
  attr_accessor :base
  attr_accessor :domain
  attr_accessor :bind_dn
  attr_accessor :charset
  
  ## Initializer.
  def initialize(params = nil)
    unless params
      conf = Util::Config.load(:ldap)
      params = {
        :host => conf['host'], 
        :port => conf['port'],
        :base => conf['base'],
        :domain => conf['domain'],
        :bind_dn => conf['bind_dn'],
        :charset => conf['charset']
      }
    end
    self.host = params[:host]
    self.port = params[:port]
    self.base = params[:base]
    self.domain = params[:domain]
    self.bind_dn = params[:bind_dn] || "uid=[uid],[ous],[base]"
    self.charset = params[:charset] || "utf-8"
    
    return nil if host.blank? || port.blank? || base.blank?
    
    self.connection = self.class.connect(params)
  end
  
  ## Connect.
  def self.connect(params)
    begin
      require 'ldap'
      timeout(2) do
        conn = LDAP::Conn.new(params[:host], params[:port])
        conn.set_option(LDAP::LDAP_OPT_PROTOCOL_VERSION, 3)
        return conn
      end
    rescue Timeout::Error => e
      raise "LDAP: 接続に失敗 (#{e})"
    rescue Exception => e
      raise "LDAP: エラー (#{e})"
    end
  end
  
  ## Bind.
  def bind(dn, pass)
    if(RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/)
      require 'nkf'
      dn = NKF.nkf('-s -W', dn)
    end
    return connection.bind(dn, pass)
  rescue LDAP::ResultError
    return nil
  end
  
  ## Group.
  def group
    Sys::Lib::Ldap::Group.new(self)
  end
  
  ## User
  def user
    Sys::Lib::Ldap::User.new(self)
  end
  
  ## Search.
  def search(filter, options = {})
    filter = "(#{filter.join(')(')})" if filter.class == Array
    filter = "(&#{filter})"
    
    cname = options[:class] || Sys::Lib::Ldap::Entry
    scope = options[:scope] || LDAP::LDAP_SCOPE_SUBTREE || LDAP::LDAP_SCOPE_ONELEVEL
    base  = options[:base]  || self.base
    entries = []
    connection.search2(base, scope, filter) do |entry|
      entry.each{|k,vs| entry[k] = vs.map{|v| NKF::nkf('-w', v.to_s)}} if charset != 'utf-8'
      entries << cname.new(self, entry)
    end
    
    return entries
  rescue
    return []
  end
end