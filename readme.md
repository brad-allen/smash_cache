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