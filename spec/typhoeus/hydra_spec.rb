require 'spec_helper'

describe Typhoeus::Hydra do
  before(:all) do
    cache_class = Class.new do
      def initialize
        @cache = {}
      end
      def get(key)
        @cache[key]
      end
      def set(key, object, timeout = 0)
        @cache[key] = object
      end
    end
    @cache = cache_class.new
  end

  it "has a singleton" do
    Typhoeus::Hydra.hydra.should be_a Typhoeus::Hydra
  end

  it "has a setter for the singleton" do
    Typhoeus::Hydra.hydra = :foo
    Typhoeus::Hydra.hydra.should == :foo
    Typhoeus::Hydra.hydra = Typhoeus::Hydra.new
  end

  it "queues a request" do
    hydra = Typhoeus::Hydra.new
    hydra.queue Typhoeus::Request.new("http://localhost:3000")
  end

  it "runs a batch of requests" do
    hydra  = Typhoeus::Hydra.new
    first  = Typhoeus::Request.new("http://localhost:3000/first")
    second = Typhoeus::Request.new("http://localhost:3001/second")
    hydra.queue first
    hydra.queue second
    hydra.run
    first.response.body.should include("first")
    second.response.body.should include("second")
  end

  it "runs queued requests in order of queuing" do
    hydra  = Typhoeus::Hydra.new :max_concurrency => 1
    first  = Typhoeus::Request.new("http://localhost:3000/first")
    second = Typhoeus::Request.new("http://localhost:3001/second")
    third = Typhoeus::Request.new("http://localhost:3001/third")
    second.on_complete do |response|
      first.response.should_not == nil
      third.response.should == nil
    end
    third.on_complete do |response|
      first.response.should_not == nil
      second.response.should_not == nil
    end

    hydra.queue first
    hydra.queue second
    hydra.queue third
    hydra.run
    first.response.body.should include("first")
    second.response.body.should include("second")
    third.response.body.should include("third")
  end

  it "should store the curl return codes on the reponses" do
    hydra  = Typhoeus::Hydra.new
    first  = Typhoeus::Request.new("http://localhost:3001/?delay=1", :timeout => 100)
    second = Typhoeus::Request.new("http://localhost:3999", :connect_timout => 100)
    hydra.queue first
    hydra.queue second
    hydra.run
    first.response.curl_return_code == 28
    second.response.curl_return_code == 7
  end

  it "aborts a batch of requests" do
    urls = [
        'http://localhost:3000',
        'http://localhost:3001',
        'http://localhost:3002'
    ]

    # this will make testing easier
    hydra     = Typhoeus::Hydra.new( :max_concurrency => 1 )
    completed = 0

    10.times do |i|
        req = Typhoeus::Request.new( urls[ i % urls.size], :params => { :cnt => i } )
        req.on_complete do |res|
            completed += 1
            hydra.abort if completed == 5
        end
        hydra.queue( req )
    end
    hydra.run
    completed.should == 6
  end

  it "has a cache_setter proc" do
    hydra = Typhoeus::Hydra.new
    hydra.cache_setter do |request|
      # @cache.set(request.cache_key, request.response, request.cache_timeout)
    end
  end

  it "has a cache_getter" do
    hydra = Typhoeus::Hydra.new
    hydra.cache_getter do |request|
      # @cache.get(request.cache_key) rescue nil
    end
  end

  it "memoizes GET reqeusts" do
    hydra  = Typhoeus::Hydra.new
    first  = Typhoeus::Request.new("http://localhost:3000/foo", :params => {:delay => 1})
    second = Typhoeus::Request.new("http://localhost:3000/foo", :params => {:delay => 1})
    hydra.queue first
    hydra.queue second
    start_time = Time.now
    hydra.run
    first.response.body.should include("foo")
    first.handled_response.body.should include("foo")
    first.response.should == second.response
    first.handled_response.should == second.handled_response
    (Time.now - start_time).should < 1.2 # if it had run twice it would be ~ 2 seconds
  end

  it "can turn off memoization for GET requests" do
    hydra  = Typhoeus::Hydra.new
    hydra.disable_memoization
    first  = Typhoeus::Request.new("http://localhost:3000/foo")
    second = Typhoeus::Request.new("http://localhost:3000/foo")
    hydra.queue first
    hydra.queue second
    hydra.run
    first.response.body.should include("foo")
    first.response.object_id.should_not == second.response.object_id
  end

  it "pulls GETs from cache" do
    hydra  = Typhoeus::Hydra.new
    start_time = Time.now
    hydra.cache_getter do |request|
      @cache.get(request.cache_key) rescue nil
    end
    hydra.cache_setter do |request|
      @cache.set(request.cache_key, request.response, request.cache_timeout)
    end

    first  = Typhoeus::Request.new("http://localhost:3000/foo", :params => {:delay => 1})
    @cache.set(first.cache_key, :foo, 60)
    hydra.queue first
    hydra.run
    (Time.now - start_time).should < 0.1
    first.response.should == :foo
  end

  it "sets GET responses to cache when the request has a cache_timeout value" do
    hydra  = Typhoeus::Hydra.new
    hydra.cache_getter do |request|
      @cache.get(request.cache_key) rescue nil
    end
    hydra.cache_setter do |request|
      @cache.set(request.cache_key, request.response, request.cache_timeout)
    end

    first  = Typhoeus::Request.new("http://localhost:3000/first", :cache_timeout => 0)
    second = Typhoeus::Request.new("http://localhost:3000/second")
    hydra.queue first
    hydra.queue second
    hydra.run
    first.response.body.should include("first")
    @cache.get(first.cache_key).should == first.response
    @cache.get(second.cache_key).should be_nil
  end

  it "continues queued requests after a queued cache hit" do
    # Set max_concurrency to 1 so that the second and third requests will end
    # up in the request queue.
    hydra  = Typhoeus::Hydra.new :max_concurrency => 1
    hydra.cache_getter do |request|
      @cache.get(request.cache_key) rescue nil
    end
    hydra.cache_setter do |request|
      @cache.set(request.cache_key, request.response, request.cache_timeout)
    end

    first  = Typhoeus::Request.new("http://localhost:3000/first", :params => {:delay => 1})
    second = Typhoeus::Request.new("http://localhost:3000/second", :params => {:delay => 1})
    third = Typhoeus::Request.new("http://localhost:3000/third", :params => {:delay => 1})
    @cache.set(second.cache_key, "second", 60)
    hydra.queue first
    hydra.queue second
    hydra.queue third
    hydra.run

    first.response.body.should include("first")
    second.response.should == "second"
    third.response.body.should include("third")
  end

  it "has a global on_complete" do
    foo = nil
    hydra  = Typhoeus::Hydra.new
    hydra.on_complete do |response|
      foo = :called
    end

    first  = Typhoeus::Request.new("http://localhost:3000/first")
    hydra.queue first
    hydra.run
    first.response.body.should include("first")
    foo.should == :called
  end

  it "has a global on_complete setter" do
    foo = nil
    hydra  = Typhoeus::Hydra.new
    proc = Proc.new {|response| foo = :called}
    hydra.on_complete = proc

    first  = Typhoeus::Request.new("http://localhost:3000/first")
    hydra.queue first
    hydra.run
    first.response.body.should include("first")
    foo.should == :called
  end

  it "should reuse connections from the pool for a host"

  it "should queue up requests while others are running" do
    hydra   = Typhoeus::Hydra.new

    start_time = Time.now
    @responses = []

    request = Typhoeus::Request.new("http://localhost:3000/first", :params => {:delay => 1})
    request.on_complete do |response|
      @responses << response
      response.body.should include("first")
    end

    request.after_complete do |object|
      second_request = Typhoeus::Request.new("http://localhost:3001/second", :params => {:delay => 2})
      second_request.on_complete do |response|
        @responses << response
        response.body.should include("second")
      end
      hydra.queue second_request
    end
    hydra.queue request

    third_request = Typhoeus::Request.new("http://localhost:3002/third", :params => {:delay => 3})
    third_request.on_complete do |response|
      @responses << response
      response.body.should include("third")
    end
    hydra.queue third_request

    hydra.run
    @responses.size.should == 3
    (Time.now - start_time).should < 3.3
  end

  it "should fire and forget" do
    # this test is totally hacky. I have no clue how to make it verify. I just look at the test servers
    # to verify that stuff is running
    hydra  = Typhoeus::Hydra.new
    first  = Typhoeus::Request.new("http://localhost:3000/first?delay=1")
    second = Typhoeus::Request.new("http://localhost:3001/second?delay=2")
    hydra.queue first
    hydra.queue second
    hydra.fire_and_forget
    third = Typhoeus::Request.new("http://localhost:3002/third?delay=3")
    hydra.queue third
    hydra.fire_and_forget
    sleep 3 # have to do this or future tests may break.
  end

  it "should take the maximum number of concurrent requests as an argument" do
    hydra = Typhoeus::Hydra.new(:max_concurrency => 2)
    first  = Typhoeus::Request.new("http://localhost:3000/first?delay=1")
    second = Typhoeus::Request.new("http://localhost:3001/second?delay=1")
    third  = Typhoeus::Request.new("http://localhost:3002/third?delay=1")
    hydra.queue first
    hydra.queue second
    hydra.queue third

    start_time = Time.now
    hydra.run
    finish_time = Time.now

    first.response.code.should == 200
    second.response.code.should == 200
    third.response.code.should == 200
    (finish_time - start_time).should > 2.0
  end

  it "should respect the follow_location option when set on a request" do
    hydra = Typhoeus::Hydra.new
    request = Typhoeus::Request.new("http://localhost:3000/redirect", :follow_location => true)
    hydra.queue request
    hydra.run

    request.response.code.should == 200
  end

  it "should pass through the max_redirects option when set on a request" do
    hydra = Typhoeus::Hydra.new
    request = Typhoeus::Request.new("http://localhost:3000/bad_redirect", :max_redirects => 5)
    hydra.queue request
    hydra.run

    request.response.code.should == 302
  end
end

describe Typhoeus::Hydra::Callbacks do
  before(:all) do
    @klass = Typhoeus::Hydra
  end

  describe "#after_request_before_on_complete" do
    it "should provide a global hook after a request" do
      begin
        http_method = nil
        @klass.after_request_before_on_complete do |request|
          http_method = request.method
        end

        hydra = @klass.new
        request = Typhoeus::Request.new('http://localhost:3000',
                                        :method => :get)
        response = Typhoeus::Response.new(:code => 404,
                                          :headers => "whatever",
                                          :body => "not found",
                                          :time => 0.1)
        hydra.queue(request)
        hydra.run

        http_method.should == :get
      ensure
        @klass.clear_global_hooks
      end
    end
  end
end

describe Typhoeus::Hydra::ConnectOptions do
  before(:all) do
    @klass = Typhoeus::Hydra
  end

  let!(:old_net_connect) { @klass.allow_net_connect }
  let!(:old_ignore_localhost) { @klass.ignore_localhost }
  let(:hydra) { @klass.new }

  after(:each) do
    @klass.allow_net_connect = old_net_connect
    @klass.ignore_localhost = old_ignore_localhost
  end

  def request_for(host)
    Typhoeus::Request.new("http://#{host}:3000")
  end

  describe "#ignore_localhost" do
    context "when set to true" do
      before(:each) { @klass.ignore_localhost = true }

      [true, false].each do |val|
        it "allows localhost requests when allow_net_connect is #{val}" do
          @klass.allow_net_connect = val
          expect { hydra.queue(request_for('localhost')) }.to_not raise_error
        end
      end
    end

    context "when set to false" do
      before(:each) { @klass.ignore_localhost = false }

      it "allows localhost requests when allow_net_connect is true" do
        @klass.allow_net_connect = true
        expect { hydra.queue(request_for('localhost')) }.to_not raise_error
      end

      it "does not allow localhost requests when allow_net_connect is false" do
        @klass.allow_net_connect = false
        expect { hydra.queue(request_for('localhost')) }.to raise_error(Typhoeus::Hydra::NetConnectNotAllowedError)
      end
    end
  end

  describe "#ignore_hosts" do
    context 'when allow_net_connect is set to false' do
      before(:each) do
        @klass.ignore_localhost = false
        @klass.allow_net_connect = false
      end

      Typhoeus::Request::LOCALHOST_ALIASES.each do |disallowed_host|
        ignore_hosts = Typhoeus::Request::LOCALHOST_ALIASES - [disallowed_host]

        context "when set to #{ignore_hosts.join(' and ')}" do
          before(:each) { @klass.ignore_hosts = ignore_hosts }

          it "does not allow a request to #{disallowed_host}" do
            expect { hydra.queue(request_for(disallowed_host)) }.to raise_error(Typhoeus::Hydra::NetConnectNotAllowedError)
          end

          ignore_hosts.each do |host|
            it "allows a request to #{host}" do
              expect { hydra.queue(request_for(host)) }.to_not raise_error
            end
          end
        end
      end
    end
  end

  describe "#allow_net_connect" do
    it "should be settable" do
      @klass.allow_net_connect = true
      @klass.allow_net_connect.should be_true
    end

    it "should default to true" do
      @klass.allow_net_connect.should be_true
    end

    it "should raise an error if we queue a request while its false" do
      @klass.allow_net_connect = false
      @klass.ignore_localhost = false

      expect {
        hydra.queue(request_for('example.com'))
      }.to raise_error(Typhoeus::Hydra::NetConnectNotAllowedError)
    end
  end

  describe "#allow_net_connect?" do
    it "should return true by default" do
      @klass.allow_net_connect?.should be_true
    end
  end
end
