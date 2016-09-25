#  SmashCache
### A simple caching and sweeping utility

### There are only two hard things in Computer Science: cache invalidation and naming things.   -Phil Karlton

  After much research at the time I could not find a simple caching utility that handled sweeping in a good way (if at all).
  For better or worse, I opted to write my own and started with a sample file caching utility and updated it to use rails_cache and mem_cache.  

  Smash Cache allows individual and tag based sweeping, so you can basically cache an item with multiple keys.  
  I use the tagging to save data under data id specific keys and under general keys to sweep/clear entire groups of cached items.
  When data is updated or created, I can use the generic restful endpoints to sweep all the necessary cached data - I generally put these sweep helper in a separate class.

## Example use:
Include this Utility file somewhere, I put mine in lib/utility/smash_cache.rb  -- this example is structured around that

Place in the config, and update the appropriate parent class to create these as config vars

### environment config
    config.smash_cache.enabled = true
    config.smash_cache.default_cache_type = :rails_cache(or :mem_cache)

### configuration.rb
    @smash_cache = ActiveSupport::OrderedOptions.new
    @smash_cache.enabled              = false
    @smash_cache.default_cache_type   = :rails_cache

### Prep in an initializer
    API_CACHE = Utility::SmashCache.new 'api_cache', 30.minutes, true, 50, 'cache_monitors/cache_stats/hits', 'cache_monitors/cache_stats/misses', 'cache_monitors/cache_stats/cached_object_count'

      where the fields are as follows:
      new_namespace, default_expire, is_wide_net_flush, action_default_count, hit_key, miss_key, cached_item_count_key, cache_type, cache_path = nil, expire_log_path

### Log a cache creation time if you want...
    API_CACHE.replace '/started_cache', '{ "api_cache_started":' + DateTime.now.strftime('%Y_%m_%d %H:%M %Ss').to_s.to_s + '}', nil

    Later, refer to the hits, misses, and object count cache keys you just created to get the stats

### Use it...

    Place (something like) these in the class or base class where @data is the data to cache or retrieve from the cache
```
   def cache_api_call expires = 1.hour
     tag_array = Array.newadd a tag if you need, this one removes the query string to group all similar restful routes in one group to make sweeping endpoints with paging easier
     tag_array.push request.original_fullpath.split('?').first.to_ssplit off the query string and use the root url as the cache tag, could also just use a constant string as the tag per controller/action/etc
     API_CACHE.add(request.original_fullpath, @data.to_json, expires, tag_array)
   end

   def check_api_cache
#Add CORS checking if needed for cross domin calls
    cached_results = API_CACHE.find request.original_fullpath
    render :json => cached_results, :status => :ok and return unless cached_results.blank?
   end
```

### In your controllers you can add this, which will only be called if check_api_cache fails
    if your cache does fail, cache_api_call will be called at the end of this controller call, caching the call
```
    def show
      @data = Dog.find params[:id]
      if @data.nil?
        render :json => Errors.unprocessable_entity('Dog', params[:id]), :status => :unprocessable_entity
      else
        render :json => @data, :status => :ok
      end
    end
```

### call (something like) these methods using the appropriate before_filter or after_filter
```
    before_filter :check_api_cache, :except => [:create_dog] if Utility::SmashCache.enabled?
    after_filter :cache_api_call, :except => [:create_dog] if Utility::SmashCache.enabled? && !@data.blank?
```

### Sweeping
    by key and tag...
      key = exact match
      tag  = generally used when sweep for multiple sets of data should be done based upon a single action
        eg: the one above removed the query string on the url request (the key of the cache in this example) 
           to group all similar restful routes in one group to make sweeping endpoints with paging and search filters easier

### Example Sweeping

```
     def self.sweep_dog_data dog_id
       return unless Utility::SmashCache.enabled?
       API_CACHE.smash('/v1/dogs/' + dog_id.to_s) unless dog_id.blank?
     end

 #Assuming the caches were all tagged with the root url
 #This would sweep indexes with any type of paging or filtering query string
 #Could also just use a constant string as the tag per controller/action
     def self.sweep_index_endpoints
       return unless Utility::SmashCache.enabled?

       API_CACHE.smash_by_tag('/v1/dogs')
       API_CACHE.smash_by_tag('/v1/dog_shows')
       end
     end
```

TODO Refactor, restructure, more...
TODO Tests
