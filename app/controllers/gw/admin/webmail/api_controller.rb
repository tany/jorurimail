# encoding: utf-8
class Gw::Admin::Webmail::ApiController < ApplicationController
  include Sys::Controller::Admin::Auth
  protect_from_forgery :except => [:unseen, :recent]
  
  def unseen
    unseen_and_recent
    
    respond_to do |format|
      format.xml { }
    end
  end
  
  def recent
    unseen_and_recent
    
    respond_to do |format|
      format.xml { }
    end
  end
  
protected
  
  def login_temporarily(account, password, mobile_password)
    if request.mobile?
      login_ok = new_login_mobile(account, password, mobile_password)
    else
      login_ok = new_login(account, password)
    end
    if login_ok
      Core.user          = current_user
      Core.user.password = Util::String::Crypt.decrypt(session[PASSWD_KEY])
      Core.user_group    = current_user.groups[0]
      Core.current_user  = Core.user
      yield
      reset_session
    end
  end
  
  def unseen_and_recent
    @unseen = -1
    @recent = -1
    @mailboxes = []
    
    if params[:account] && params[:password]
      @account = params[:account]
      login_temporarily(params[:account], params[:password], params[:mobile_password]) do
        @unseen = 0
        @recent = 0
        @mailboxes = Gw::WebmailMailbox.load_mailboxes(:all)
        @mailboxes.each do |box|
          next if box.name =~ /^(Sent|Drafts|Trash|Star)(\.|$)/
          @unseen += box.unseen
          @recent += box.recent
        end
      end
    end
  end
end