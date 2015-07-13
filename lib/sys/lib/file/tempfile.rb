# encoding: utf-8
require 'shared-mime-info'
class Sys::Lib::File::Tempfile < Tempfile
  
  def initialize(options = {})
    @filename = options[:filename]
    super([File::basename(@filename), File::extname(@filename)])
    binmode
    write(options[:data])
    rewind
    self
  end
  
  def original_filename
    @filename
  end
  
  def content_type
    MIME.check_globs(@tmpname).type rescue nil
  end
end