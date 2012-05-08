# require File.expand_path('../c_zookeeper', __FILE__)

require_relative 'c_zookeeper'
require 'forwardable'

# The low-level wrapper-specific methods for the C lib
# subclassed by the top-level Zookeeper class
module Zookeeper
class ZookeeperBase
  extend Forwardable
  include Zookeeper::Forked
  include Zookeeper::Common       # XXX: clean this up, no need to include *everything*
  include Zookeeper::Callbacks
  include Zookeeper::Constants
  include Zookeeper::Exceptions
  include Zookeeper::ACLs

  attr_accessor :original_pid

  # @private
  class ClientShutdownException < StandardError; end

  # @private
  KILL_TOKEN = Object.new unless defined?(KILL_TOKEN)

  ZKRB_GLOBAL_CB_REQ   = -1

  # debug levels
  ZOO_LOG_LEVEL_ERROR  = 1
  ZOO_LOG_LEVEL_WARN   = 2
  ZOO_LOG_LEVEL_INFO   = 3
  ZOO_LOG_LEVEL_DEBUG  = 4


  # this is unfortunately necessary to prevent a really horrendous race in
  # shutdown, where some other thread calls close in the middle of a
  # synchronous operation (thanks to the GIL-releasing wrappers, we now
  # have this problem). so we need to make sure only one thread can be calling
  # a synchronous operation at a time. 
  #
  # this might be solved by waiting for a condition where there are no "in flight"
  # operations (thereby allowing multiple threads to make requests simultaneously),
  # but this would represent quite a bit of added complexity, and questionable
  # performance gains.
  #
  def self.synchronized_delegation(provider, *syms)
    syms.each do |sym|
      class_eval(<<-EOM, __FILE__, __LINE__+1)
        def #{sym}(*a, &b)
          @mutex.synchronize { #{provider}.#{sym}(*a, &b) }
        end
      EOM
    end
  end

  synchronized_delegation :@czk, :get_children, :exists, :delete, :get, :set,
    :set_acl, :get_acl, :client_id, :sync, :wait_until_connected

  # some state methods need to be more paranoid about locking to ensure the correct
  # state is returned
  # 
  def self.threadsafe_inquisitor(*syms)
    syms.each do |sym|
      class_eval(<<-EOM, __FILE__, __LINE__+1)
        def #{sym}
          false|@mutex.synchronize { @czk and @czk.#{sym} }
        end
      EOM
    end
  end

  threadsafe_inquisitor :connected?, :connecting?, :associating?, :running?

  attr_reader :event_queue
 
  def reopen(timeout = 10, watcher=nil)
    if watcher and (watcher != @default_watcher)
      raise "You cannot set the watcher to a different value this way anymore!"
    end

    reopen_after_fork! if forked?

    @mutex.synchronize do
      # flushes all outstanding watcher reqs.
      @watcher_reqs.clear
      set_default_global_watcher

      orig_czk, @czk = @czk, CZookeeper.new(@host, @event_queue)

      orig_czk.close if orig_czk
      
      @czk.wait_until_connected(timeout)
    end

    setup_dispatch_thread!
    state
  end

  def initialize(host, timeout = 10, watcher=nil)
    @watcher_reqs = {}
    @completion_reqs = {}

    @after_fork_hooks = []

    update_pid!  # from Forked

    @current_req_id = 0

    # set up state that also needs to be re-setup after a fork()
    reopen_after_fork!
    
    @czk = nil
    
    # approximate the java behavior of raising java.lang.IllegalArgumentException if the host
    # argument ends with '/'
    raise ArgumentError, "Host argument #{host.inspect} may not end with /" if host.end_with?('/')

    @host = host

    @default_watcher = (watcher or get_default_global_watcher)

    yield self if block_given?

    reopen(timeout)
  end

  # if either of these happen, the user will need to renegotiate a connection via reopen
  def assert_open
    @mutex.synchronize do
      raise Exceptions::SessionExpired if state == ZOO_EXPIRED_SESSION_STATE
      raise Exceptions::NotConnected   unless connected?
      if forked?
        raise InheritedConnectionError, <<-EOS.gsub(/(?:^|\n)\s*/, ' ').strip
          You tried to use a connection inherited from another process [#{@pid}]
          You need to call reopen() after forking
        EOS
      end
    end
  end

  # do not lock, do not mutex, just close the underlying handle this is
  # potentially dangerous and should only be called after a fork() to close
  # this instance
  def close!
    @czk && @czk.close
  end

  # close the connection normally, stops the dispatch thread and closes the
  # underlying connection cleanly
  def close
    shutdown_thread = Thread.new do
      @mutex.synchronize do
        stop_dispatch_thread!
        @czk.close
      end
    end

    shutdown_thread.join unless event_dispatch_thread?
  end

  # the C lib doesn't strip the chroot path off of returned path values, which
  # is pretty damn annoying. this is used to clean things up.
  def create(*args)
    # since we don't care about the inputs, just glob args
    rc, new_path = @mutex.synchronize { @czk.create(*args) }
    [rc, strip_chroot_from(new_path)]
  end

  def set_debug_level(int)
    warn "DEPRECATION WARNING: #{self.class.name}#set_debug_level, it has moved to the class level and will be removed in a future release"
    self.class.set_debug_level(int)
  end

  # set the watcher object/proc that will receive all global events (such as session/state events)
  def set_default_global_watcher
    warn "DEPRECATION WARNING: #{self.class}#set_default_global_watcher ignores block" if block_given?

    @mutex.synchronize do
#       @default_watcher = block # save this here for reopen() to use
      @watcher_reqs[ZKRB_GLOBAL_CB_REQ] = { :watcher => @default_watcher, :watcher_context => nil }
    end
  end

  def state
    return ZOO_CLOSED_STATE if closed?
    @mutex.synchronize { @czk.state }
  end

  def session_id
    @mutex.synchronize do
      cid = client_id and cid.session_id
    end
  end

  def session_passwd
    @mutex.synchronize do
      cid = client_id and cid.passwd
    end
  end

  # we are closed if there is no @czk instance or @czk.closed?
  def closed?
    @mutex.synchronize { !@czk or @czk.closed? } 
  end
 
protected
  # this method may be called in either the fork case, or from the constructor
  # to set up this state initially (so all of this is in one location). we rely
  # on the forked? method to determine which it is
  def reopen_after_fork!
    logger.debug { "#{self.class}##{__method__}" }
    @mutex = Monitor.new
    @dispatch_shutdown_cond = @mutex.new_cond
    @event_queue = @event_queue ? @event_queue.clone_after_fork : QueueWithPipe.new

    if @dispatcher and not @dispatcher.alive?
      logger.debug { "#{self.class}##{__method__} re-starting dispatch thread" }
      @dispatcher = nil
      setup_dispatch_thread!
    end

    update_pid!
  end

  # this is a hack: to provide consistency between the C and Java drivers when
  # using a chrooted connection, we wrap the callback in a block that will
  # strip the chroot path from the returned path (important in an async create
  # sequential call). This is the only place where we can hook *just* the C
  # version. The non-async manipulation is handled in ZookeeperBase#create.
  # 
  def setup_completion(req_id, meth_name, call_opts)
    if (meth_name == :create) and cb = call_opts[:callback]
      call_opts[:callback] = lambda do |hash|
        # in this case the string will be the absolute zookeeper path (i.e.
        # with the chroot still prepended to the path). Here's where we strip it off
        hash[:string] = strip_chroot_from(hash[:string])

        # call the original callback
        cb.call(hash)
      end
    end

    # pass this along to the Zookeeper::Common implementation
    super(req_id, meth_name, call_opts)
  end

  # if we're chrooted, this method will strip the chroot prefix from +path+
  def strip_chroot_from(path)
    return path unless (chrooted? and path and path.start_with?(chroot_path))
    path[chroot_path.length..-1]
  end

  def get_default_global_watcher
    Proc.new { |args|
      logger.debug { "Ruby ZK Global CB called type=#{event_by_value(args[:type])} state=#{state_by_value(args[:state])}" }
      true
    }
  end

  def chrooted?
    !chroot_path.empty?
  end

  def chroot_path
    if @chroot_path.nil?
      @chroot_path = 
        if idx = @host.index('/')
          @host.slice(idx, @host.length)
        else
          ''
        end
    end

    @chroot_path
  end
end
end
