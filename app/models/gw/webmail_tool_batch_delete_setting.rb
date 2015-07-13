# encoding: utf-8
class Gw::WebmailToolBatchDeleteSetting < Sys::Model::ActiveModel
  attr_accessor :mailbox_id, :start_date, :end_date
  attr_accessor :include_starred
  
  validates_presence_of :mailbox_id
  validates_each :start_date, :end_date do |model, attr, value|
    if value !~ /^\d{4}\/\d{2}\/\d{2}$/
      model.errors.add(attr, 'のフォーマットが不正です。')
    else
      DateTime.parse(value) rescue model.errors.add(attr, 'の日付が不正です。')
    end
  end
  
  def batch_delete_mails(mailboxes)
    delete_num = 0
    changed_mailboxes = []
    
    mailbox_id = self.mailbox_id.to_i
    sent_since = Time.parse(self.start_date).strftime("%d-%b-%Y")
    sent_before = (Time.parse(self.end_date) + 1.days).strftime("%d-%b-%Y")
    
    mailboxes.each do |box|
      next if box.name =~ /^(Star)$/
      next if mailbox_id != 0 && mailbox_id != box.id 
      
      condition = ['SENTSINCE', sent_since, 'SENTBEFORE', sent_before]
      condition << 'UNFLAGGED' if self.include_starred == '0'
      
      Core.imap.select(box.name)
      uids = Core.imap.uid_search(condition)
      num = Core.imap.uid_store(uids, "+FLAGS", [:Deleted]).size rescue 0
      Core.imap.expunge
      
      if num > 0
        Gw::WebmailMailNode.delete_nodes(box.name, uids)
        changed_mailboxes << box.name
      end
      
      delete_num += num
      
      starred_uids = Gw::WebmailMailNode.find_ref_nodes(box.name, uids).map{|x| x.uid}
      Core.imap.select('Star')
      num = Core.imap.uid_store(starred_uids, "+FLAGS", [:Deleted]).size rescue 0
      Core.imap.expunge
      if num > 0
        Gw::WebmailMailNode.delete_ref_nodes(box.name, uids)
      end
    end
    
    if delete_num > 0
      Gw::WebmailMailbox.load_mailboxes(:all)
      Gw::WebmailMailbox.load_quota(:force)
    end
    
    delete_num
  end
end