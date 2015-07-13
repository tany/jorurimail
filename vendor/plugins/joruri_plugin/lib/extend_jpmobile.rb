# encoding: utf-8

# mobile_filter
Rails.application.config.jpmobile.mobile_filter
Rails.application.config.jpmobile.form_accept_charset_conversion = true

# source from jpmobile-0.0.8 start
module Jpmobile::Mobile
  # ==SoftBank 2G携帯電話(J-PHONE/Vodafone 2G)
  # スーパクラスはVodafone。
  class Jphone < Vodafone
    # 対応するUser-Agentの正規表現
    USER_AGENT_REGEXP = /^(J-PHONE|J-EMULATOR)/
    # 対応するメールアドレスの正規表現
    MAIL_ADDRESS_REGEXP = /^.+@jp-[dhtcrknsq]\.ne\.jp$/

    # 位置情報があれば Position のインスタンスを返す。無ければ +nil+ を返す。
    def position
      str = @request.env["HTTP_X_JPHONE_GEOCODE"]
      return nil if str.nil? || str == "0000000%1A0000000%1A%88%CA%92%75%8F%EE%95%F1%82%C8%82%B5"
      raise "unsuppoted format" unless str =~ /^(\d\d)(\d\d)(\d\d)%1A(\d\d\d)(\d\d)(\d\d)%1A(.+)$/
      pos = Jpmobile::Position.new
      pos.lat = Jpmobile::Position.dms2deg($1,$2,$3)
      pos.lon = Jpmobile::Position.dms2deg($4,$5,$6)
      pos.options = {"address"=>NKF.nkf("-m0 -Sw", CGI.unescape($7))}
      pos.tokyo2wgs84!
      return pos
    end

    # cookieに対応しているか？
    def supports_cookie?
      false
    end
  end
end
# source from jpmobile-0.0.8 end

module Jpmobile::Mobile
  @carriers << 'Jphone'
end

module Jpmobile
  module RequestWithMobile
    def mobile?
      mobile
    end
  end
end

module Jpmobile::Mobile
  class AbstractMobile
    def variants
      return @_variants if @_variants

      @_variants = self.class.ancestors.select {|c| c.to_s =~ /^Jpmobile/}.map do |klass|
        klass = klass.to_s.
          gsub(/Jpmobile::/, '').
          gsub(/AbstractMobile::/, '').
          gsub(/Mobile::SmartPhone/, 'smart_phone').
          gsub(/::/, '_').
          gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').
          gsub(/([a-z\d])([A-Z])/, '\1_\2').
          downcase
        klass =~ /abstract/ ? "mobile" : klass
      end
      
      if @_variants.include?("smart_phone")
        @_variants = @_variants.reject{|v| v == "mobile"}.map{|v| v.gsub(/mobile/, "smart_phone")}
        @_variants << 'mobile'
      end
      
      @_variants
    end
  end
end

module Jpmobile::Mobile
  class Docomo < AbstractMobile
    def default_charset
      "UTF-8"
    end
    def to_internal(str)
      str
    end
    def to_external(str, content_type, charset)
      [str, charset]
    end
  end
end

module Jpmobile
  module Util
    module_function
    def sjis(str)
      if str.respond_to?(:force_encoding) and !shift_jis?(str)
        str = NKF.nkf('-s -x --oc=CP932', str)
        str.force_encoding(SJIS)
      end
      str
    end
    def utf8(str)
      if str.respond_to?(:force_encoding) and !utf8?(str)
        str = NKF.nkf('-w', str)
        str.force_encoding(UTF8)
      end
      str
    end
    def jis(str)
      if str.respond_to?(:force_encoding) and !jis?(str)
        str = NKF.nkf('-j', str)
        str.force_encoding(JIS)
      end
      str
    end
    def utf8_to_sjis(utf8_str)
      # 波ダッシュ対策
      utf8_str = wavedash_to_fullwidth_tilde(utf8_str)
      NKF.nkf("-m0 -x -W --oc=cp932", utf8_str).gsub(/\n/, "\r\n")
    end
    def sjis_to_utf8(sjis_str)
      utf8_str = NKF.nkf("-m0 -x -w --ic=cp932", sjis_str).gsub(/\r\n/, "\n")
      # 波ダッシュ対策
      fullwidth_tilde_to_wavedash(utf8_str)
    end
    def utf8_to_jis(utf8_str)
      NKF.nkf("-m0 -x -Wj", utf8_str).gsub(/\n/, "\r\n")
    end
    def jis_to_utf8(jis_str)
      NKF.nkf("-m0 -x -Jw", jis_str).gsub(/\r\n/, "\n")
    end
  end
end

module Jpmobile::Mobile
  class Docomo < AbstractMobile
    def supports_cookie?
      imode_browser_version != '1.0' && imode_browser_version !~ /^2.0/
    end
  end
end

case Joruri.config.application['sys.force_site']
when 'mobile'
  module Jpmobile::Mobile
    class Others < SmartPhone
      USER_AGENT_REGEXP = /./
    end
  end
  
  module Jpmobile::Mobile
    @carriers << 'Others'
  end
when 'pc'
  module Jpmobile::Mobile
    @carriers = []
  end
end