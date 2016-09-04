module Utility

  ######################################################
  # SmashCache
  # A simple caching and sweeping utility
  #
  # There are only two hard things in Computer Science: cache invalidation and naming things.   -Phil Karlton
  #
  # After much research at the time I could not find a simple caching utility that handled sweeping in a good way (if at all).
  # For better or worse, I opted to write my own and started with a sample file caching utility and updated it to use rails_cache and mem_cache.  
  #
  # Smash Cache allows individual and tag based sweeping, so you can basically cache an item with multiple keys.  
  # I use the tagging to save data under data id specific keys and under general keys to sweep/clear entire groups of cached items.
  # When data is updated or created, I can use the generic restful endpoints to sweep all the necessary cached data - I generally put these sweep helper in a separate class.
  #
  # The file caching is not as fully implemented as the other two at this time and will probably be removed as it was more of an experiment so treaat it as Deprecated
  # See list at the bottom for other TODOs and deficiencies 
  #
  # #Example use:
  #
  # Include this file somewhere, I put mine in lib/utility/smash_cache.rb  -- this example is structured around that
  #
  # #Place in the config, and update the appropriate parent class to create these as config vars
  #
  # #environment config
  # config.smash_cache.enabled = true
  # config.smash_cache.default_cache_type = :rails_cache  #(or :file or :mem_cache)
  #
  # #configuration.rb
  # @smash_cache = ActiveSupport::OrderedOptions.new
  # @smash_cache.enabled              = false
  # @smash_cache.default_cache_type   = :rails_cache
  #
  # #Prep in an initializer
  # API_CACHE = Utility::SmashCache.new 'api_cache', 30.minutes, true, 50, 'app_monitors/api_cache/hit_count', 'app_monitors/api_cache/miss_count', 'app_monitors/api_cache/cached_object_count'
  # #Log a cache creation time if you want...
  # API_CACHE.replace '/started_cache', '{ "api_cache_started":' + DateTime.now.strftime('%Y_%m_%d %H:%M %Ss').to_s.to_s + '}', nil
  #
  # #Use it...
  #
  # Place (something like) these in the class or base class where @data is the data to cache or retrieve from the cache
  #
  #  def cache_api_call expires = 1.hour
  #    tag_array = Array.new  #add a tag if you need, this one removes the query string to group all similar restful routes in one group to make sweeping endpoints with paging easier
  #    tag_array.push request.original_fullpath.split('?').first.to_s  #split off the query string
  #    API_CACHE.add(request.original_fullpath, @data.to_json, expires, tag_array)
  #  end
  #
  #  def check_api_cache
  #   #Add CORS checking if needed for cross domin calls
  #   cached_results = API_CACHE.find request.original_fullpath
  #   render :json => cached_results, :status => :ok and return unless cached_results.blank?
  #  end
  #
  # In your controllers you can add this, which will only be called if check_api_cache fails
  # if your cache does fail, cache_api_call will be called at the end of this controller call, caching the call
  #
  # def show
  #   @data = Dog.find params[:id]
  #   if @data.nil?
  #     render :json => Errors.unprocessable_entity('Dog', params[:id]), :status => :unprocessable_entity
  #   else
  #     render :json => @data, :status => :ok
  #   end
  # end
  #
  # #call (something like) these methods using the appropriate before_filter or after_filter
  #
  # before_filter :check_api_cache, :except => [:create_dog,dog :properties] if Utility::SmashCache.enabled?
  # after_filter :cache_api_call, :except => [:create_dog, :properties] if Utility::SmashCache.enabled? && !@data.blank?
  #
  # Sweeping
  # by key, key pattern and tag...
  # key = exact match
  # pattern, :rails_cache and :file only - not recommended for :rails_cache (slow - use tagging functionality instead), recommended for :file (directory deletion)
  # tag, :rails_cache and :mem_cache only - use in lieu of pattern for mem_cache (mem_cache doesn't support it) - can push in multiple tags for one set of @data results
  #
  # Example Sweeping
  #
  #  def self.sweep_dog_data dog_id
  #    return unless Utility::SmashCache.enabled?
  #    API_CACHE.smash_by_pattern('/v1/dogs/' + dog_id.to_s) unless dog_id.blank?
  #  end
  #
  #  def self.sweep_all_dog_endpoints dog_id=nil
  #    return unless Utility::SmashCache.enabled?
  #
  #    API_CACHE.smash_by_pattern('/v1/dogs')
  #    API_CACHE.smash_by_pattern('/v1/dogs/' + dog_id.to_s) unless dog_id.blank?
  #
  #    dogshow = DogShow.find_by_dog_id dog_id
  #    API_CACHE.smash_by_pattern('/v1/dog_shows')
  #    API_CACHE.smash_by_pattern('/v1/dog_shows/' + dogshow.to_s) unless dogshow.blank?
  #    end
  #  end
  #
  #######################################################
  #
  # TODO Refactor, restructure, consolidate multiple/confusing concepts (patterns vs tags)
  # TODO Better instructions and samples
  # TODO Tests
  # TODO Cleanup sweeping and functionality deficiencies in different types 
  # TODO File caching issues, race conditions, tagging, etc -  or remove file caching?
  #
  #######################################################

  class SmashCache

    CACHE_NAMESPACE = 'default'

    SMASH_CACHE_FILE_EXTENSION = '.sc'
    SMASH_CACHE_FILE_EXT_LENGTH = SMASH_CACHE_FILE_EXTENSION.length
    EXPIRE_CACHE_FILE_EXTENSION = '.ex'
    INFO_LOG_FILE_EXTENSION = '.il'
    DATA_LOG_FILE_NAME = 'cache_data.dl'

    CACHE_PATH = "#{Rails.root}/smash_cache/"
    EXPIRE_LOG_PATH = CACHE_PATH + "expire_logs/"

    MAX_NUM_OBJECTS = 5000  #:file only -- only an approximate for now due to pattern sweeping...  TODO - deal with bad count
    ACTION_DEFAULT_COUNT = 250  #the number of find actions performed before it writes to hit count, miss count, and object count cache fields

    #A class variable to shut off all cache instances
    @@enabled = (Rails.application.config.smash_cache.blank? || Rails.application.config.smash_cache.enabled.blank?) ? false : Rails.application.config.smash_cache.enabled

    def self.enabled?
      @@enabled
    end

    def initialize new_namespace = nil, default_expire = nil, is_wide_net_flush = nil, action_default_count = nil,  hit_key = '/hits', miss_key = '/misses', cached_item_count_key = '/object_count', cache_type = nil, max_num_objects = nil, cache_path = nil, expire_log_path = nil
      @hit_count = 0
      @miss_count = 0
      @current_object_count = 0
      @max_num_objects =  MAX_NUM_OBJECTS

      @action_count = 0
      @action_default_count = ACTION_DEFAULT_COUNT

      @cache_path = CACHE_PATH
      @expire_log_path = EXPIRE_LOG_PATH

      @default_namespace = CACHE_NAMESPACE.to_s
      @full_cache_path = CACHE_PATH + @default_namespace.to_s
      @default_expire = 1.hour
      @wide_net_flush = true

      if (Rails.application.config.smash_cache.present? && Rails.application.config.smash_cache.default_cache_type.present? &&
          (Rails.application.config.smash_cache.default_cache_type == :mem_cache ||
           Rails.application.config.smash_cache.default_cache_type == :file ||
           Rails.application.config.smash_cache.default_cache_type == :rails_cache))
        @cache_type  = Rails.application.config.smash_cache.default_cache_type
      else
        @cache_type = :rails_cache
      end

      reset_fields new_namespace, default_expire, is_wide_net_flush, action_default_count, hit_key, miss_key, cached_item_count_key, cache_type, max_num_objects, cache_path, expire_log_path
    end

    def get_cache_type
      return :disabled unless @@enabled
      @cache_type
    end

    def update_defaults new_namespace = nil, default_expire = nil, is_wide_net_flush = nil, action_default_count = nil, hit_key = nil, miss_key = nil, cached_item_count_key = nil, cache_type = nil, max_num_objects = nil, cache_path = nil, expire_log_path = nil
      reset_fields new_namespace, default_expire, is_wide_net_flush, action_default_count,  hit_key, miss_key, cached_item_count_key, cache_type, max_num_objects, cache_path, expire_log_path
    end

    def exists? key
      return false unless @@enabled
      begin
        key = shorten_key key
        full_cache_path = get_full_path key
        exists = false
        exists = file_exists? full_cache_path if @cache_type == :file
        exists = mem_cache_exists? full_cache_path if @cache_type == :rails_cache || @cache_type == :mem_cache
        exists
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in exists? - Key: ' + key.blank? ? '' : key.to_s + ' - Exception: ' + e
        return false
      end
    end

    def find key
      return nil unless @@enabled
      begin
        key = shorten_key key
        full_cache_path = get_full_path key
        data = nil
        data = get_file_data(full_cache_path) if @cache_type == :file
        data = get_mem_cache_data(full_cache_path) if @cache_type == :rails_cache || @cache_type == :mem_cache
        data
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in find - Key: ' + key.blank? ? '' : key.to_s + ' - Exception: ' + e
        return nil
      end
    end

    def add key, data, expires = @default_expire, tags = nil
      begin
        return false unless @@enabled
        key = shorten_key key
        full_cache_path = get_full_path key
        created = false
        created = create_file(full_cache_path, data, expires) if @cache_type == :file
        created = create_mem_cache(full_cache_path, data, expires) if @cache_type == :rails_cache || @cache_type == :mem_cache
        add_tags(tags, key, expires) if @cache_type != :file && created && !tags.blank?
        created
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in add - Key: ' + key.blank? ? '' : key.to_s + ' - Expires: ' + expires.inspect unless expires.blank? + ' - Exception: ' + e
        return false
      end
    end

    def replace key, data, expires = @default_expire, tags = nil
      begin
        return false unless @@enabled
        key = shorten_key key
        full_cache_path = get_full_path key

        replaced = false
        replaced = overwrite_file(full_cache_path, data, expires) if @cache_type == :file
        replaced = overwrite_mem_cache(full_cache_path, data, expires) if @cache_type == :rails_cache || @cache_type == :mem_cache
        add_tags(tags, key, expires) if @cache_type != :file && replaced && !tags.blank?   #TODO Issue with tags and file caching
        replaced
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in replace - Key: ' + key.blank? ? '' : key.to_s + ' - Expires: ' + expires.inspect unless expires.blank? + ' - Exception: ' + e
        return false
      end
    end

    def smash key, wide_net_flush= @wide_net_flush, namespace = @default_namespace
      begin
        return unless @@enabled
        key = shorten_key key
        @hold_namespace = @default_namespace
        @default_namespace = namespace
        full_cache_path = get_full_path key

        delete_file(full_cache_path, wide_net_flush) if @cache_type == :file
        delete_rails_cache(full_cache_path, wide_net_flush) if @cache_type == :rails_cache
        if @cache_type == :mem_cache && @wide_net_flush
          #assume tagged if wide net flush = true
          tag_path = get_tag_path key
          delete_mem_cache_by_tag tag_path
        else
          delete_mem_cache full_cache_path
        end

        @default_namespace = @hold_namespace
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in smash - Key: ' + key.blank? ? '' : key.to_s + ' - Wide Net Flush: ' + @wide_net_flush.inspect unless @wide_net_flush.blank? + ' - Exception: ' + e
       end
    end

    def smash_by_pattern key, namespace = @default_namespace
      begin
        return unless @@enabled
        key = shorten_key key
        @hold_namespace = @default_namespace
        @default_namespace = namespace
        full_pattern_cache_path = get_full_pattern_path key

        delete_file(full_cache_path, wide_net_flush) if @cache_type == :file
        delete_rails_cache_by_pattern(full_pattern_cache_path) if @cache_type == :rails_cache

        if @cache_type == :mem_cache
          tag_path = get_tag_path key
          delete_mem_cache_by_tag tag_path
        end

        @default_namespace = @hold_namespace
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in smash_by_pattern - Key: ' + key.blank? ? '' : key.to_s + ' - Exception: ' + e
      end
    end

    def smash_by_tag tag
      begin
        return unless @@enabled
        error_notify 'SmashCache Notification: File caching cannot use tags yet.  Use smash_by_pattern' and return if @cache_type == :file
        tag = shorten_key tag
        tag_path = get_tag_path tag
        delete_mem_cache_by_tag tag_path
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception in smash_by_pattern - Key: ' + key.blank? ? '' : key.to_s + ' - Exception: ' + e
      end
    end

    def smash_the_cache! namespace = @default_namespace
      begin
        return unless @@enabled
        delete_file_namespace(namespace) if @cache_type == :file
        delete_rails_cache_namespace(namespace) if @cache_type == :rails_cache

        # Can really only drop full cache easily with mem_cache --> Rails.cache.clear
        error_notify 'SmashCache Notification: ' + namespace.to_s + ' namespace smashed!' if @cache_type == :file || @cache_type == :rails_cache
        error_notify 'SmashCache Notification: Memcached namespace cannot be smashed yet!  smash entire memcache with --> Rails.cache.clear' if @cache_type == :mem_cache
      rescue Exception => e
        Rails.logger.error 'SmashCache Exception - Key: ' + key.blank? ? '' : key.to_s + ' - Exception: ' + e
        Honeybadger.notify(e)
      end
    end

    #--------------------#
    protected
    #--------------------#

    def write_cached_object_count
      if @cache_type == :file
        write_to_data_log '{"object_data" : {"count":' + @current_object_count.to_s + ', "time":"' + DateTime.now.strftime('%Y-%m-%d %H:%M:%S').to_s + '" }}'
      end

      if @cache_type == :rails_cache || @cache_type == :mem_cache
        begin
          Rails.cache.write @cached_item_count_key, @current_object_count.to_s unless @cached_item_count_key.blank?
        rescue Exception => e
          Rails.logger.error 'Failing SmashCache Cached Object Count for Namespace:' + @default_namespace.blank? ? '' : @default_namespace.to_s + ' - Exception:' + e
        end
      end
    end

    def write_hit_count
      if @cache_type == :file
        write_to_info_log '{"counts" : {"time":"' + DateTime.now.strftime('%Y-%m-%d %H:%M:%S').to_s + '","' + @hit_key + '":' + @hit_count.to_s + '","' + @miss_key +'":' + @miss_count.to_s + '}}'
      end

      if @cache_type == :rails_cache || @cache_type == :mem_cache
        begin
          Rails.cache.write @hit_key, @hit_count.to_s unless @hit_key.blank?
          Rails.cache.write @miss_key, @miss_count.to_s unless @miss_key.blank?
        rescue Exception => e
          Rails.logger.error 'Failing SmashCache Hit and Miss Count for Namespace:' + @default_namespace.blank? ? '' : @default_namespace.to_s + ' - Exception:' + e
        end
      end
    end

    def error_notify log_msg
      begin
        raise ArgumentError, log_msg
      rescue Exception => e
        Honeybadger.notify(e)
      end
    end

    #--------------------
    # Log Methods
    def write_to_expire_log full_cache_path, expires
      expire_time = DateTime.now + expires
      data_string = expire_time.strftime('%Y_%m_%d_%H_%M').to_s + ',' + full_cache_path.to_s
      write_to_log data_string, EXPIRE_LOG_PATH.to_s, expire_time.strftime('%Y_%m_%d_%H').to_s + EXPIRE_CACHE_FILE_EXTENSION
    end

    def write_to_data_log data_string
      #Clear out the previous ones over time or else this will get giganto!!
      write_to_log data_string, (CACHE_PATH.to_s + @default_namespace.to_s + '/'), DATA_LOG_FILE_NAME
    end

    def write_to_info_log data_string
      write_to_log data_string, (CACHE_PATH.to_s + @default_namespace.to_s + '/'), (DateTime.now.strftime('%Y_%m_%d').to_s + INFO_LOG_FILE_EXTENSION)
    end

    def write_to_log data_string, log_path, filename
      FileUtils.mkdir_p log_path unless File.exists? log_path + filename
      File.open(log_path + filename, 'a+') {|f| f.puts(data_string) }
    end

    #--------------------#
    private
    #--------------------#
    # Helper Methods

      def shorten_key key
        key = Digest::SHA1.hexdigest(key) if key.length >= 225
        key
      end

      def get_path_without_file full_cache_path
      path = full_cache_path
      path[0...(path.length-get_file(path).length)]
    end

    def get_file full_cache_path
      full_cache_path.split('/').last.to_s
    end

    def get_full_path key
      return '' if key.blank?
      full_path = ''
      full_path = (@full_cache_path + key.gsub('?',"\/")).to_s + SMASH_CACHE_FILE_EXTENSION if @cache_type == :file
      full_path = ('/' + @default_namespace.to_s +  key.gsub('?',"\/")).to_s if @cache_type == :rails_cache || @cache_type == :mem_cache
      #Rails.logger.info 'get_full_path PATH CHECK: ' + hold_test.inspect
      full_path
    end

    def get_tag_path key
      return '' if key.blank?
      tag_path = ''
      tag_path = CACHE_PATH + 'sc-tag:' + key.split('?').first.to_s + SMASH_CACHE_FILE_EXTENSION if @cache_type == :file
      tag_path = '/sc-tag:' +  key.split('?').first.to_s if @cache_type == :rails_cache || @cache_type == :mem_cache
      #Rails.logger.info 'get_tag_path PATH CHECK: ' + tag_path.inspect
      tag_path
    end

    def get_full_pattern_path key  #TODO update to work with file caching
      return '' if key.blank? || @cache_type == :file
      '/' + @default_namespace.to_s + key.to_s      #TODO add functionality to handle extra or missing slashes in the path
    end

    def reset_fields new_namespace = nil, default_expire = nil, is_wide_net_flush = nil, action_default_count = nil, hit_key = nil, miss_key = nil, cached_item_count_key = nil, cache_type = nil, max_num_objects = nil, cache_path = nil, expire_log_path = nil
      @default_namespace = new_namespace unless new_namespace.blank?
      @default_expire = default_expire unless default_expire.blank? || default_expire.minutes.to_i < 1   ##Verify this timing
      @wide_net_flush = is_wide_net_flush unless is_wide_net_flush.blank?
      @cache_type  = cache_type unless cache_type.blank? || (cache_type != :file && cache_type != :rails_cache && cache_type != :mem_cache)  #:file or :rails_cache
      @full_cache_path = CACHE_PATH + @default_namespace.to_s
      @max_num_objects =  max_num_objects unless max_num_objects.blank?
      @action_default_count = action_default_count unless action_default_count.blank? || action_default_count <= 0
      @cache_path = cache_path unless cache_path.blank?
      @expire_log_path = expire_log_path unless expire_log_path.blank?
      @hit_key = hit_key unless hit_key.blank?
      @miss_key = miss_key unless miss_key.blank?
      @cached_item_count_key = cached_item_count_key unless cached_item_count_key.blank?

      #try to load the current object count if a file based cache
      if @cache_type == :file
        data_log_path = CACHE_PATH.to_s + @default_namespace.to_s + '/' + DATA_LOG_FILE_NAME
        if File.exists? data_log_path
          file = ''
          File.open(data_log_path, "r").each_line do |line|
            file = line #just set the last one... #TODO better way to do this
          end
          begin
            @current_object_count = JSON.parse(file.as_json)["object_data"]["count"].to_i
          rescue
            @current_object_count = 0
          end
        end
      end
    end

    #make public?
    def add_tags tags, key, expires
      new_keys = ''
      tags.each do |tag|
        tag = get_tag_path tag
        if Rails.cache.exist? tag.to_s
          keys = ''
          keys = Rails.cache.read tag.to_s
          key = key.gsub('?',"\/").to_s
          # add the new one
          new_keys = (keys.to_s + ',' + '/' + @default_namespace.to_s + key.to_s) if keys.present?
        else
          key = key.gsub('?',"\/").to_s
          new_keys = '/' + @default_namespace + key
        end

        if expires.blank?
          Rails.cache.write tag, new_keys.to_s
        else
          Rails.cache.write tag, new_keys.to_s, expires_in: expires + 1.hour
        end
      end
    end

    #--------------------
    # File Cache Methods
    def file_exists? full_cache_path
      File.exists?(full_cache_path)
    end

    def get_file_data full_cache_path
      file = ''
      if File.exists? full_cache_path
        @hit_count = @hit_count + 1
        File.open(full_cache_path, "r").each_line do |line|
          file = file + line
        end
      else
        @miss_count = @miss_count + 1
      end

      @action_count = @action_count + 1
      if @action_count >= @action_default_count
        write_hit_count
        write_cached_object_count
        @action_count = 0
      end

      file
    end

    def create_file full_cache_path, data, expires
      # create file if it does not exist
      path = get_path_without_file full_cache_path
      if @current_object_count >= @max_num_objects
        Rails.logger.error 'Cache Full - cannot add more - please attend to -- Cache:' + @full_cache_path + ' - ~Object Max Reached:' + @current_object_count.to_s
      else
        unless File.exists? full_cache_path
          @current_object_count = @current_object_count + 1
          FileUtils.mkdir_p path
          File.open(full_cache_path, 'w') {|f| f.write(data) }
          write_to_expire_log full_cache_path.to_s, expires unless expires.blank?
          return true
        end
      end
      false
    end

    def overwrite_file full_cache_path, data, expires
      # create file if it does not exist, overwrite if it does
      overwritten = false
      path = get_path_without_file full_cache_path
      if @current_object_count >= @max_num_objects
        Rails.logger.error 'Cache Full - cannot add more - please attend to -- Cache:' + @full_cache_path + ' - ~Object Max Reached:' + @current_object_count.to_s
      else
        if File.exists? full_cache_path
          File.delete full_cache_path
          overwritten = true
        else
          @current_object_count = @current_object_count + 1
        end

        FileUtils.mkdir_p path
        File.open(full_cache_path, 'w') {|f| f.write(data) }
        write_to_expire_log full_cache_path, expires unless expires.blank?
      end
      overwritten
    end

    def delete_file_namespace namespace
      FileUtils.remove_dir CACHE_PATH + namespace.to_s if !namespace.blank? && File.exists?(CACHE_PATH + namespace)
      @current_object_count = 0
      write_to_data_log '{"type":"object_count", "objects":' + @current_object_count.to_s + ', "time":"' + DateTime.now.strftime('%Y-%m-%d %H:%M:%S').to_s + '" }'
    end


    ## errors in here with smash call
    def delete_file full_cache_path, wide_net_flush
      # delete file if exists
      if File.exists? full_cache_path
        File.delete full_cache_path
        @current_object_count = @current_object_count - 1
        if wide_net_flush
          FileUtils.remove_dir(full_cache_path[0...full_cache_path.to_s.length-SMASH_CACHE_FILE_EXT_LENGTH] + '/').to_s
          #Not sure how many are here unless we do it recursively ## Replace this with delete_folder_recursively
          ##@current_object_count = @current_object_count - 1
        end
      end

    end

    #--------------------
    # Memcache and RailsCache methods
    def mem_cache_exists? full_cache_path
      Rails.cache.exist? full_cache_path.to_s
    end

    def get_mem_cache_data full_cache_path
      file = ''
      if Rails.cache.exist? full_cache_path
        file = Rails.cache.read full_cache_path
        @hit_count = @hit_count + 1
      else
        @miss_count = @miss_count + 1
      end

      @action_count = @action_count + 1
      if @action_count >= @action_default_count
        write_hit_count
        write_cached_object_count
        @action_count = 0
      end

      file
    end

    def delete_rails_cache full_cache_path, wide_net_flush
      # delete file if exists
      return if !Rails.cache.exist? full_cache_path

      if wide_net_flush
        Rails.cache.delete_matched (full_cache_path + '*')
        @current_object_count = @current_object_count - 1  ####??? get real count
      else
        Rails.cache.delete full_cache_path
        @current_object_count = @current_object_count - 1
      end
    end

    def delete_mem_cache full_cache_path
      # delete file if exists
      return if !Rails.cache.exist? full_cache_path

      Rails.cache.delete key
      @current_object_count = @current_object_count - 1

    end

    def delete_rails_cache_by_pattern full_cache_pattern_path
      Rails.cache.delete_matched full_cache_pattern_path
      @current_object_count = @current_object_count - 1  ####??? get real count
    end

    def delete_mem_cache_by_tag tag
      if Rails.cache.exist? tag
        keys = Rails.cache.read tag
        key_array = keys.split(',')

        key_array.each do |key|
          Rails.cache.delete key
          @current_object_count = @current_object_count - 1
        end
        #ok, now delete the tag
        Rails.cache.delete tag
      end
    end

    def create_mem_cache full_cache_path, data, expires
      unless Rails.cache.exist? full_cache_path
        @current_object_count = @current_object_count + 1
        if expires.blank?
          Rails.cache.write full_cache_path, data
        else
          Rails.cache.write full_cache_path, data, expires_in: expires
        end
        return true
      end
      false
    end

    def overwrite_mem_cache full_cache_path, data, expires
      existed = Rails.cache.exist? full_cache_path
      @current_object_count = (@current_object_count + 1) unless existed
      overwritten = false
      overwritten = true if existed
      begin
        if expires.blank?
          Rails.cache.write full_cache_path, data
        else
          Rails.cache.write full_cache_path, data, expires_in: expires
        end
      rescue Exception => e
        Rails.logger.error 'Failing SmashCache write to MemCache' + e
      end
      overwritten
    end

    def delete_rails_cache_namespace namespace
      Rails.cache.delete_matched ('/' + namespace + '/*').to_s   #update pattern
      @current_object_count = 0
      #write_to_data_log '{"type":"object_count", "objects":' + @current_object_count.to_s + ', "time":"' + DateTime.now.strftime('%Y-%m-%d %H:%M:%S').to_s + '" }'
    end
  end
end
