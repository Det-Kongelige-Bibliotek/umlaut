# The search controller handles searches fo manually entered citations,
# or possibly ambiguous citations generally. It also provides an A-Z list.
#
# As source of this data, it can either use an Umlaut local journal index
# (supplemented by the SFX API for date-sensitive querries),
# or it can instead talk directly to the SFX db (still supplemented
# by the API).  Whether it uses the journal index depends on
# the value of the app config parameter use_umlaut_journal_index.
#
# Otherwise, it'll try to talk to the SFX db directly using
# a database config named 'sfx_db' defined in config/database.yml 
#
# In either case, for talking to SFX API, how does it know where to find the
# SFX to talk to? You can either define it in app config param
# 'search_sfx_base_url', or if not defined there, the code will try to find
# by looking at default Institutions for SFX config info.  
class SearchController < ApplicationController
  require 'open_url'
  
  layout AppConfig.param("search_layout","search_basic"), :except => [ :opensearch, :opensearch_description ]

  before_filter :normalize_params
  
  def index
    self.journals
  	render :action=>'journals'    
  end  
  
  def journals
  
  end

  # @search_results is an array of ContextObject objects.
  # Or, redirect to resolve action for single hit.
  # param umlaut.title_search_type (aka sfx.title_search) 
  # can be 'begins', 'exact', or 'contains'. Other
  # form params should be OpenURL, generally
  def journal_search
    
    @batch_size = 10
    @page = 1
    @page = params[:'umlaut.page'].to_i if params[:'umlaut.page']
    @start_result_num = (@page * @batch_size) - (@batch_size - 1)
    
    search_co = context_object_from_params
        
    # If we have an exact-type 'search', just switch to 'resolve' action
    if (params["umlaut.title_search_type"] == 'exact' or params["rft.object_id"] or params["rft.issn"] or params[:rft_id_value])
      redirect_to search_co.to_hash.merge!(:controller=>'resolve')
    elsif ( @use_umlaut_journal_index )
      # Not exact search, and use local index. .
      @total_search_results = self.find_via_local_title_source()
    else
      # Talk to SFX via direct db.
      @total_search_results = self.find_by_title_via_sfx_db()
    end

    @total_search_results = [] if @total_search_results.nil?
    
    
    @hits = @total_search_results.length
    # Take out just the slice that we want to display.
    if @hits < (@page + @batch_size)
      @end_result_num = @hits
    else
      @end_result_num = @start_result_num + @batch_size - 1 
    end
    @display_results = @total_search_results.slice(@start_result_num - 1, @batch_size) 

    # Supplement them with our original context object, so date/vol/iss/etc
    # info is not lost.
    orig_metadata = search_co.referent.metadata
    @display_results.each do | co |
      orig_metadata.each do |k,v|        
        # Don't overwrite, just supplement
        co.referent.set_metadata(k, v) unless co.referent.get_metadata(k) || v.blank?
      end
    end

    
    if @display_results.length == 1
      # If we narrowed down to one result, redirect to resolve action.        
      redirect_to @display_results[0].to_hash.merge!(:controller=>'resolve')      
    end


  end

  def journal_list
    require 'journals/sfx_journal'
    @journals = Journal.find_all_by_page(params[:id].downcase, :order=>'normalized_title')

  end  

  def context_object_from_params
    params_c = params.clone  

    # Take out the weird ones that aren't really part of the OpenURL
    ignored_keys = [:journal, "__year", "__month", "__day", "action", "controller", "Generate_OpenURL2", "rft_id_type", "rft_id_value"]
    ignored_keys.each { |k| params_c.delete(k) }
    
    # Enhance and normalize metadata a bit, before
    # making a context object
    jrnl = nil
    # Normalize ISSN to have dash
    if ( ! params['rft.issn'].blank? && params['rft.issn'][4,1] != '-')
      params[rft.issn].insert(4,'-')
    end

    # Enhance with info from local journal index, if we can
    if ( @use_umlaut_journal_index)
      # Try a few different ways to find a journal object
      jrnl = Journal.find_by_object_id(params_c['rft.object_id']) unless params_c['rft.object_id'].blank?
      jrnl = Journal.find_by_issn(params_c['rft.issn']) unless jrnl || params_c['rft.issn'].blank?
      jrnl = Journal.find(:first, :conditions=>['lower(title) = ?',params_c['rft.jtitle']]) unless (jrnl || params_c['rft.jtitle'].blank?)
 
      if (jrnl && params_c['rft.issn'].blank?)
        params_c['rft.issn'] = jrnl.issn
      end
      if (jrnl && params_c['rft.object_id'].blank? )
        params_c['rft.object_id'] = jrnl[:object_id]
      end
      if (jrnl && params_c['rft.jtitle'].blank?)
        params_c['rft.jtitle'] = jrnl.title
      end
    end
    

    ctx = OpenURL::ContextObject.new
    ctx.import_hash( params_c )

    # Not sure where ":rft_id_value" as opposed to 'rft_id' comes from, but
    # it was in old code. We do it after CO creation to handle multiple
    # identifiers
    if (! params_c[:rft_id_value].blank?)
      ctx.referent.add_identifier( params_c[:rft_id_value] )
    end

    return ctx
  end

  def init_context_object_and_resolve
    co = context_object_from_params

    # Add our controller param to the context object, and redirect
    redirect_to co.to_hash.merge!(:controller=>'resolve')
  end

  def init_context_object_and_resolve_old
    ctx = OpenURL::ContextObject.new  
    jrnl = nil
    if (params["rft.object_id"] )
      jrnl = Journal.find_by_object_id(params["rft.object_id"]) if @use_umlaut_journal_index
      ctx.referent.set_metadata('object_id', params["rft.object_id"])
    end

    unless params["rft.jtitle"].blank? 
      ctx.referent.set_metadata('jtitle', params["rft.jtitle"])
    end
    if (! params["rft.issn"].blank?)
      issn = params["rft.issn"]
     	unless issn[4,1] == "-"
     	  issn.insert(4, '-')
     	end
     	ctx.referent.set_metadata('issn', issn)
    elsif jrnl and jrnl.issn
      ctx.referent.set_metadata('issn', jrnl.issn)
    end
    if ctx.referent.metadata['issn'] or ctx.referent.metadata['jtitle']
      if (@use_umlaut_journal_index && ! jrnl)
        if ctx.referent.metadata['issn']
          jrnl = Journal.find_by_issn(ctx.referent.metadata['issn'])
          ctx.referent.set_metadata('object_id', jrnl[:object_id]) if jrnl
          ctx.referent.set_metadata('jtitle', jrnl.title) if jrnl
        else
          jrnl = Journal.find(:first, :conditions=>['lower(title) = ?',ctx.referent.metadata['jtitle']])
          if jrnl
            ctx.referent.set_metadata('object_id', jrnl[:object_id])
            ctx.referent.set_metadata('issn', jrnl.issn) if jrnl.issn
          end
        end
      end
    end
    ctx.referent.set_metadata('date', params['rft.date']) if params['rft.date']
    ctx.referent.set_metadata('volume', params['rft.volume']) if params['rft.volume']
    ctx.referent.set_metadata('volume', params['rft.issue']) if params['rft.issue']

    # Not sure where rft_id_value instead of rft_id would come from?
    # Normalizing is taken care of inside referent code. 
    ctx.referent.set_identifier(params[:rft_id_value]) unless params[:rft_id_value].blank?
    ctx.referent.set_identifier(params[:rft_id]) unless params[:rft_id].blank?
    
    
    redirect_to ctx.to_hash.merge!(:controller=>'resolve')
  end
  

  # Should return an array of hashes, with each has having :title and :object_id
  # keys. Can come from local journal index or SFX or somewhere else.
  # :object_id is the SFX rft.object_id, and can be blank. (I think it's SFX
  # rft.object_id for local journal index too)
  def auto_complete_for_journal_title
    if (@use_umlaut_journal_index)
      @titles = Journal.find_by_contents("alternate_titles:*"+params['rft.jtitle']+"*").collect {|j| {:object_id => j[:object_id], :title=> j.title }   }
    else
      #lookup in SFX db directly!
      #query = params[:journal][:title].upcase
      query = params['rft.jtitle']
      
      
      @titles = SfxDb::AzTitle.find(:all, :conditions => ['TITLE_NORMALIZED like ?', "%" + query + "%"]).collect {|to| {:object_id => to.OBJECT_ID, :title=>to.TITLE_DISPLAY}
      }
    end
    
    render :partial => 'journal_titles'
  end

  # Talk directly to SFX mysql to find the hits by journal Title.  
  # Works with SFX 3.0. Will probably break with SFX 4.0, naturally.
  # Returns an Array of ContextObjects. 
  def find_by_title_via_sfx_db
    # NORMALIZED TITLE column in SFX db appears to be upcase title
    # Frustratingly, NORMALIZED_TITLE does not remove non-filing chars,
    # so we need to do a fairly expensive search. 
  
    search_type = params['umlaut.title_search_type'] || 'contains'
    title_q = params['rft.jtitle']
    
    conditions = case search_type
      when 'contains'
        ['TITLE_NORMALIZED like ?', "%" + title_q.upcase + "%"]
      when 'begins'
       ['TITLE_NORMALIZED like ? OR mid(TITLE_NORMALIZED, TITLE_NON_FILING_CHAR) like ?', title_q.upcase + '%', title_q.upcase + '%']
      else # exact
        ['TITLE_NORMALIZED = ? OR mid(TITLE_NORMALIZED, TITLE_NON_FILING_CHAR) =  ?', title_q.upcase, title_q.upcase]
    end
    
    object_ids = SfxDb::Title.find(:all, :conditions => conditions).collect { |title_obj| title_obj.OBJECT_ID}

    # Now fetch objects with publication information
    sfx_objects = SfxDb::Object.find( object_ids, :include => [:publishers, :main_titles, :primary_issns, :primary_isbns])

    # Now we need to convert to ContextObjects.
    context_objects = sfx_objects.collect do |sfx_obj|
      ctx = OpenURL::ContextObject.new

      # Put SFX object id in rft.object_id, that's what SFX does. 
      ctx.referent.set_metadata('object_id', sfx_obj.id)

      publisher_obj = sfx_obj.publishers.first
      if ( publisher_obj )
        ctx.referent.set_metadata('pub', publisher_obj.PUBLISHER_DISPLAY)
        ctx.referent.set_metadata('place', publisher_obj.PLACE_OF_PUBLICATION_DISPLAY)
      end
      
      title_obj = sfx_obj.main_titles.first
      title = title_obj ? title_obj.TITLE_DISPLAY : "Unknown Title"
      ctx.referent.set_metadata('jtitle', title)

      issn_obj = sfx_obj.primary_issns.first
      ctx.referent.set_metadata('issn', issn_obj.ISSN_ID) if issn_obj

      isbn_obj = sfx_obj.primary_isbns.first     
      ctx.referent.set_metadata('isbn', isbn_obj.ISBN_ID) if isbn_obj
      
      ctx
    end
  end

  # This guy actually works to talk to an SFX instance over API.
  # But it's really slow. And SFX doesn't seem to take account
  # of year/volume/issue when displaying multiple results anyway!!
  # So it does nothing of value for us. 
  def find_via_remote_title_source(context_object)
      ctx = context_object
      search_results = []

      sfx_url = AppConfig.param("search_sfx_base_url")
      unless (sfx_url)      
        # try to guess it from our institutions
        instutitions = Institution.find_all_by_default_institution(true)
        instutitions.each { |i| i.services.each { |s| 
           sfx_url = s.base_url if s.kind_of?(Sfx) }}      
      end
            
      transport = OpenURL::Transport.new(sfx_url, ctx)
      transport.extra_args["sfx.title_search"] = params["sfx.title_search"]
      transport.extra_args["sfx.response_type"] = 'multi_obj_xml'

      require 'ruby-debug'
      debugger
      
      transport.transport_inline
      
      doc = REXML::Document.new transport.response
      
      #client = SfxClient.new(ctx, resolver)
      
      doc.elements.each('ctx_obj_set/ctx_obj') { | ctx_obj | 
        ctx_attr = ctx_obj.elements['ctx_obj_attributes']
        next unless ctx_attr and ctx_attr.has_text?
        
        perl_data = ctx_attr.get_text.value
        search_results << Sfx.parse_perl_data( perl_data )
      } 
      return search_results     
  end
  
  def find_via_local_title_source
    offset = 0
    offset = ((params[:page].to_i * 10)-10) if params['page']

    unless session[:search] == {:title_search=>params['sfx.title_search'], :title=>params['rft.jtitle']}
      session[:search] = {:title_search=>params['sfx.title_search'], :title=>params['rft.jtitle']}

      titles = case params['sfx.title_search']    
        when 'begins'          
          Journal.find(:all, :conditions=>['lower(title) LIKE ?', params['rft.jtitle'].downcase+"%"], :offset=>offset)
        else
          qry = params['rft.jtitle']
          qry = '"'+qry+'"' if qry.match(/\s/)        
          options = {:limit=>:all, :offset=>offset}
          Journal.find_by_contents('alternate_titles:'+qry, options)         
        end
      
      ids = []
      titles.each { | title |
        ids << title.journal_id
      }   
      session[:search_results] = ids.uniq
    end
    @hits = session[:search_results].length
    if params[:page]
      start_idx = (params[:page].to_i*10-10)
    else
      start_idx = 0
    end
    if session[:search_results].length < start_idx + 9
      end_idx = (session[:search_results].length - 1)
    else 
      end_idx = start_idx + 9
    end
    search_results = []
    if session[:search_results].length > 0
      Journal.find(session[:search_results][start_idx..end_idx]).each {| journal |
        co = OpenURL::ContextObject.new
        co.referent.set_metadata('jtitle', journal.title)
        unless journal.issn.blank?
          co.referent.set_metadata('issn', journal.issn)
        end
        co.referent.set_format('journal')
        co.referent.set_metadata('genre', 'journal')
        co.referent.set_metadata('object_id', journal[:object_id])
        search_results << co
      }
    end
    return search_results
  end

  def rescue_action_in_public(exception)
    if @action_name == 'journal_list'
      render :template => "error/journal_list_error" 
    else
      render :template => "error/search_error"
    end
  end   
  
  def opensearch
    require 'opensearch_feed'
    if params['type'] and params['type'] != ""
      type = params['type']
    else
      type = 'atom'
    end
    
    if params[:type] == 'json'
      self.json_response
      return
    end
    if params['page'] and params['page'] != ""
      offset = (params['page'].to_i * 25) - 25
    else
      params['page'] = "1"
      offset = 0
    end
    titles = Journal.find_by_contents(params['query'], {:limit=>25, :offset=>offset})
    search_results = []
    if titles
      for title in titles do

      end
    end
    attrs={:search_terms=>params['query'], :total_results=>titles.total_hits.to_s,
      :start_index=>offset.to_s, :count=>"25"}
    feed = FeedTools::OpensearchFeed.new(attrs)
    feed.title = "Search for "+params['query']
    feed.author = "Georgia Tech Library"
    feed.id='http://'+request.host+request.request_uri
    feed.previous_page = url_for(:action=>'opensearch', :query=>params['query'], :page=>(params['page'].to_i - 1).to_s, :type=>type) unless params['page'] == 1
    last = titles.total_hits/25
    feed.next_page=url_for(:action=>'opensearch', :query=>params['query'], :page=>(params['page'].to_i + 1).to_s, :type=>type) unless params['page'] == last.to_s
    feed.last_page=url_for(:action=>'opensearch', :query=>params['query'], :page=>last.to_s, :type=>type)
    feed.href=CGI::escapeHTML('http://'+request.host+request.request_uri)
    feed.search_page=url_for(:action=>'opensearch_description')
    feed.feed_type = params[:type]
    titles.each do |title|
      co = OpenURL::ContextObject.new
      co.referent.set_metadata('jtitle', title.title)
      issn = nil
      if title.issn
        co.referent.set_metadata('issn', title.issn)
        issn = title.issn
      elsif title.eissn
        co.referent.set_metadata('eissn', title.eissn)      
        title.eissn
      end
      co.referent.set_format('journal')
      co.referent.set_metadata('genre', 'journal')
      co.referent.set_metadata('object_id', title.object_id)
      search_results << co    
      f = FeedTools::FeedItem.new
      
      f.title = co.referent.metadata['jtitle']
      f.title << " ("+issn+")" if issn
      f.link= url_for co.to_hash.merge({:controller=>'resolve'})
      f.id = f.link
      smry = []
      title.coverages.each do | cvr |
        smry << cvr.provider+':  '+cvr.coverage unless smry.index(cvr.provider+':  '+cvr.coverage)
      end
      f.summary = smry.join('<br />')
      feed << f
    end    
  	@headers["Content-Type"] = "application/"+type+"+xml"
  	render_text feed.build_xml    
            
  end 
  
  def json_response
    if params[:page] and params[:page] != ""
      offset = (params['page'].to_i * 25) - 25
    else
      params[:page] = "1"
      offset = 0
    end
    journals = Journal.find_by_contents(params['query'], {:limit=>25, :offset=>offset})
    
    results={:searchTerms=>params['query'], :totalResults=>journals.total_hits,
      :startIndex=>offset, :itemsPerPage=>"25", :items=>[]}

    results[:title] = "Search for "+params['query']
    results[:author] = "Georgia Tech Library"
    results[:description] = "Georgia Tech Library eJournals"
    results[:id] = 'http://'+request.host+request.request_uri
    results[:previous] = url_for(:action=>'opensearch', :query=>params['query'], :page=>(params[:page].to_i - 1).to_s, :type=>type) unless params[:page] == 1
    last = journals.total_hits/25
    results[:next]=url_for(:action=>'opensearch', :query=>params['query'], :page=>(params[:page].to_i + 1).to_s, :type=>type) unless params[:page] == last.to_s
    results[:last]=url_for(:action=>'opensearch', :query=>params['query'], :page=>last.to_s, :type=>type)
    results[:href]=CGI::escapeHTML('http://'+request.host+request.request_uri)
    results[:search]=url_for(:action=>'opensearch_description')
  
    journals.each {|result|
      issn = ''
      if result.issn
        issn = ' ('+result.issn+')'
      elsif result.eissn
        issn = ' ('+result.eissn+')'      
      end
      item = {:title=>result.title+issn}
      co = OpenURL::ContextObject.new
      co.referent.set_format('journal')
      co.referent.set_metadata('issn', issn) unless issn.blank?
      co.referent.set_metadata('jtitle', result.title)
      item[:link]= url_for(co.to_hash.merge({:controller=>'resolve'}))
      item[:id] = item[:link]
      smry = []
      result.coverages.each do | cvr |
        smry << cvr.provider+':  '+cvr.coverage unless smry.index(cvr.provider+':  '+cvr.coverage)
      end
      item[:description] = smry.join('<br />')      
      item[:author] = "Georgia Tech Library"
      results[:items] << item
    }    
  	@headers["Content-Type"] = "text/plain"
  	render_text results.to_json
  end
    
  
  def opensearch_description
    @headers['Content-Type'] = 'application/opensearchdescription+xml' 
  end

  protected

  # We store our params in our session so we can tell if we have the same
  # query or not. 
  #def store_format(params)
    # Got to take out params that actually aren't about the query at all.
  #  store_format = params.clone
  #  store_format.delete("action")
  #  store_format.delete("controller")
  #  store_format.delete("page")
    
  #  return store_format
  #end

  def normalize_params
    # sfx.title_search and umlaut.title_search_type are synonyms
    params["sfx.title_search"] = params["umlaut.title_search_type"] if params["sfx.title_search"].blank?
    params["umlaut.title_search_type"] = params["sfx.title_search"] if params["umlaut.title_search_type"].blank?
    
    # Likewise, params[:journal][:title] is legacy params['rft.jtitle']
    unless (params[:journal].blank? || params[:journal][:title].blank? ||
            ! params['rft.jtitle'].blank? )
      params['rft.jtitle'] = params[:journal][:title]
    end
    if (params[:journal].blank? || params[:journal][:title].blank?)
      params[:journal] ||= {}
      params[:journal][:title] = params['rft.jtitle']
    end

    # Grab identifiers out of the way we've encoded em
    if ( params['rft_id_value'])
      id_type = params['rft_id_type'] || 'doi'
      params['rft_id'] = "info:#{id_type}/#{params['rft_id_value']}"
    end
  end
 
end
