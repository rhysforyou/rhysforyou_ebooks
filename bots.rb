require 'twitter_ebooks'

# Information about a particular Twitter user we know
class UserInfo
  attr_reader :username

  # @return [Integer] how many times we can pester this user unprompted
  attr_accessor :pesters_left

  # @param username [String]
  def initialize(username)
    @username = username
    @pesters_left = 1
  end
end

class CloneBot < Ebooks::Bot
  attr_accessor :original, :model, :model_path, :archive, :archive_path

  def configure
    # Configuration for all CloneBots
    self.consumer_key = ENV['TWITTER_CONSUMER_KEY']
    self.consumer_secret = ENV['TWITTER_CONSUMER_SECRET']
    self.blacklist = []
    self.delay_range = 1..6
    @userinfo = {}
  end

  def top100; @top100 ||= model.keywords.take(100); end
  def top20;  @top20  ||= model.keywords.take(20); end

  def on_startup
    load_archive!
    load_model!
    reload_model

    # Tweet unprompted a few times a day
    scheduler.every '1h' do
      tweet model.make_statement(140)
    end

    # Periodically ingest new tweets
    scheduler.every '24h' do
      reload_model
    end
  end

  def on_message(dm)
    delay do
      reply(dm, model.make_response(dm.text))
    end
  end

  def on_mention(tweet)
    # Become more inclined to pester a user when they talk to us
    userinfo(tweet.user.screen_name).pesters_left += 1

    delay do
      reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
    end
  end

  def on_timeline(tweet)
    return if tweet.retweeted_status?
    return unless can_pester?(tweet.user.screen_name)

    tokens = Ebooks::NLP.tokenize(tweet.text)

    interesting = tokens.find { |t| top100.include?(t.downcase) }
    very_interesting = tokens.find_all { |t| top20.include?(t.downcase) }.length > 2

    delay do
      if very_interesting
        favorite(tweet) if rand < 0.5
        retweet(tweet) if rand < 0.1
        if rand < 0.01
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      elsif interesting
        favorite(tweet) if rand < 0.05
        if rand < 0.001
          userinfo(tweet.user.screen_name).pesters_left -= 1
          reply(tweet, model.make_response(meta(tweet).mentionless, meta(tweet).limit))
        end
      end
    end
  end

  # Find information we've collected about a user
  # @param username [String]
  # @return [Ebooks::UserInfo]
  def userinfo(username)
    @userinfo[username] ||= UserInfo.new(username)
  end

  # Check if we're allowed to send unprompted tweets to a user
  # @param username [String]
  # @return [Boolean]
  def can_pester?(username)
    userinfo(username).pesters_left > 0
  end

  # Only follow our original user or people who are following our original user
  # @param user [Twitter::User]
  def can_follow?(username)
    @original.nil? || username == @original || twitter.friendship?(username, @original)
  end

  def favorite(tweet)
    if can_follow?(tweet.user.screen_name)
      super(tweet)
    else
      log "Unfollowing @#{tweet.user.screen_name}"
      twitter.unfollow(tweet.user.screen_name)
    end
  end

  def on_follow(user)
    if can_follow?(user.screen_name)
      follow(user.screen_name)
    else
      log "Not following @#{user.screen_name}"
    end
  end

  private
  def load_archive!
    return if @archive

    @archive_path ||= "corpus/#{original}.json"

    log "Loading archive #{archive_path}"
    @archive = Ebooks::Archive.new(original, @archive_path)
  end

  def load_model!
    return if @model

    @model_path ||= "model/#{original}.model"
    log "Loading model #{model_path}"
    @model = Ebooks::Model.load(model_path)

    reload_model
  end

  def reload_model
    log "Updating archive"
    @archive.sync
    log "Consuming archive"
    @model.consume(@archive_path)
    log "Saving new model"
    @model.save(@model_path)
  end
end

CloneBot.new("rhysforbot") do |bot|
  bot.access_token = ENV['TWITTER_ACCESS_TOKEN']
  bot.access_token_secret = ENV['TWITTER_ACCESS_TOKEN_SECRET']
  bot.original = "rhysforyou"
end
