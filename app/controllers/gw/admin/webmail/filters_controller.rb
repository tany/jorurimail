# encoding: utf-8
class Gw::Admin::Webmail::FiltersController < Gw::Controller::Admin::Base
  include Sys::Controller::Scaffold::Base
  layout "admin/gw/webmail"
  
  def pre_dispatch
    imap = Core.imap
    #return error_auth unless Core.user.has_auth?(:designer)
  #rescue => e
    #render :text => %Q(<div class="railsException">#{e}</div>), :layout => true
  end
  
  def index
    item = Gw::WebmailFilter.new.readable
    item.and :user_id, Core.user.id
    item.page  params[:page], params[:limit]
    item.order params[:sort], 'sort_no, id'
    @items = item.find(:all)
    _index @items
  end
  
  def show
    @item = Gw::WebmailFilter.new.find(params[:id])
    return error_auth unless @item.readable?
    
    _show @item
  end

  def new
    @item = Gw::WebmailFilter.new({
      :state            => 'enabled',
      :conditions_chain => 'and',
      :sort_no          => 0
    })
  end
  
  def create
    @item = Gw::WebmailFilter.new(params[:item])
    @item.user_id = Core.user.id
    _create(@item)
  end
  
  def update
    @item = Gw::WebmailFilter.new.find(params[:id])
    @item.attributes = params[:item]
    @item.user_id = Core.user.id
    
    _update(@item)
  end
  
  def destroy
    @item = Gw::WebmailFilter.new.find(params[:id])
    _destroy(@item)
  end
  
  def apply
    @item = Gw::WebmailFilter.new.find(params[:id])
    return error_auth unless @item.readable?
    
    @f_item = Gw::WebmailFilter.new(params[:f_item])
    return false unless request.post?
    
    ## validation
    @f_item.errors.add :base, "適用するフォルダを入力してください。" if @f_item.mailbox.blank?
    @f_item.errors.add :base, "適用する条件が見つかりません。" if @item.conditions.size == 0
    return false if @f_item.errors.size > 0
    
    @applied = 0
    message  = ""
    changed_mailbox_uids = {}
    
    begin
      timeout = Sys::Lib::Timeout.new(60)
      if @f_item.include_sub == "1"
        mailboxes = Core.imap.list('', "#{@f_item.mailbox}.*") || []
        mailboxes.each do |mailbox|
          apply_mailbox(mailbox.name, timeout)
        end
      end
      apply_mailbox(@f_item.mailbox, timeout)
    rescue Sys::Lib::Timeout::Error => ex 
      message = "タイムアウトしました。（#{ex.second}秒）<br />"
    end
    
    case @item.action
    when 'move'
      changed_mailbox_uids[@item.mailbox] = [:all]
    when 'delete'
      changed_mailbox_uids['Trash'] = [:all]
    end
    
    Gw::WebmailMailbox.load_starred_mails(changed_mailbox_uids) if @applied > 0
    Gw::WebmailMailbox.load_mailboxes(reload = true) if @applied > 0
    flash[:notice] = "#{message}#{@applied}件のメールに適用しました。".html_safe
    redirect_to :action => :apply
  end

protected
  def apply_mailbox(mailbox, timeout)
    begin
      @item.apply(:select => mailbox, :conditions => ["NOT", "DELETED"], :delete_cache => true, :timeout => timeout)
    ensure
      @applied += @item.applied
    end
  end
end
