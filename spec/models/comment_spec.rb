require 'spec_helper'

describe Comment do
  before(:each) do
    @blog = stub_default_blog
  end

  def published_article
    FactoryGirl.build_stubbed(:article, :published_at => Time.now - 1.hour)
  end

  def valid_comment(options={})
    Comment.new({:author => 'Bob',
                :article => published_article,
                :body => 'nice post',
                :ip => '1.2.3.4'}.merge(options))
  end

  describe '#permalink_url' do
    before(:each) do
      @c = FactoryGirl.build_stubbed(:comment)
    end

    subject { @c.permalink_url }

    it 'should render permalink to comment in public part' do
      should == "#{@c.article.permalink_url}#comment-#{@c.id}"
    end
  end

  describe '#edit_url' do
    it 'should get a url where edit comment in admin' do
      c = FactoryGirl.build_stubbed(:comment)
      assert_equal "http://myblog.net/admin/comments/edit/#{c.id}", c.edit_url
    end
  end

  describe '#delete_url' do
    it 'should get the delete url of comment in admin part' do
      c = FactoryGirl.build_stubbed(:comment)
      assert_equal "http://myblog.net/admin/comments/destroy/#{c.id}", c.delete_url
    end
  end

  describe '#save' do
    before(:each) {
      @blog.stub(:sp_article_auto_close) { 300 }
    }
    it 'should save good comment' do
      c = FactoryGirl.build(:comment, :url => "http://www.google.de", :article => published_article)
      assert c.save
      assert_equal "http://www.google.de", c.url
    end

    it 'should save spam comment' do
      c = FactoryGirl.build(:comment, :body => 'test <a href="http://fakeurl.com">body</a>', :article => published_article)
      assert c.save
      assert_equal "http://fakeurl.com", c.url
    end

    it 'should not save in invalid article' do
      c = valid_comment(:author => "Old Spammer",
                        :body => "Old trackback body",
                        :article => FactoryGirl.build(:article, :state => 'draft'))

      assert ! c.save
      assert c.errors['article_id'].any?
    end

    it 'should change old comment' do
      c = FactoryGirl.build(:comment, :body => 'Comment body <em>italic</em> <strong>bold</strong>', :article => published_article)
      assert c.save
      assert c.errors.empty?
    end

    it 'should save a valid comment' do
      c = valid_comment # article created 2 days ago
      c.save.should be_true
      c.errors.should be_empty
    end

    it 'should not save with article not allow comment'  do
      @blog.stub(:sp_article_auto_close) { 1 }

      c = FactoryGirl.build(:comment, :article => FactoryGirl.build_stubbed(:article, :allow_comments => false))
      c.save.should_not be_true
      c.errors.should_not be_empty
    end

  end

  describe '#create' do
    it 'should create comment' do
      c = valid_comment
      assert c.save
      assert c.guid.size > 15
    end

    it 'preserves urls starting with https://' do
      c = valid_comment(:url => 'https://example.com/')
      c.save
      c.url.should == 'https://example.com/'
    end

    it 'preserves urls starting with http://' do
      c = valid_comment(:url => 'http://example.com/')
      c.save
      c.url.should == 'http://example.com/'
    end

    it 'prepends http:// to urls without protocol' do
      c = valid_comment(:url => 'example.com')
      c.save
      c.url.should == 'http://example.com'
    end
  end

  describe '#spam?' do
    it 'should reject spam rbl' do
      c = valid_comment(:author => "Spammer",
                        :body => %{This is just some random text. &lt;a href="http://chinaaircatering.com"&gt;without any senses.&lt;/a&gt;. Please disregard.},
                        :url => "http://buy-computer.us")
      should_be_spam(c)
    end

    it 'should not define spam a comment rbl with lookup succeeds' do
      c = valid_comment(:author => "Not a Spammer",
                        :body   => "Useful commentary!",
                        :url    => "http://www.bofh.org.uk")
      c.should_not be_spam
      c.should_not be_status_confirmed
    end

    it 'should reject spam with uri limit' do
      c = valid_comment(:author => "Yet Another Spammer",
                        :body => %{ <a href="http://www.one.com/">one</a> <a href="http://www.two.com/">two</a> <a href="http://www.three.com/">three</a> <a href="http://www.four.com/">four</a> },
                        :url => "http://www.uri-limit.com")
      should_be_spam(c)
    end

    def should_be_spam(comment)
      comment.should be_spam
      comment.should_not be_status_confirmed
    end

  end

  it 'should have good relation' do
    article = FactoryGirl.build_stubbed(:article)
    comment = FactoryGirl.build_stubbed(:comment, :article => article)
    assert comment.article
    assert_equal article, comment.article
  end

  describe 'reject xss' do
    before(:each) do
      @comment = Comment.new do |c|
        c.body = "Test foo <script>do_evil();</script>"
        c.author = 'Bob'
        c.article_id = FactoryGirl.create(:article).id
      end
    end
    ['','textile','markdown','smartypants','markdown smartypants'].each do |filter|
      it "should reject with filter '#{filter}'" do
        # XXX: This makes sure text filter exists in the database
        # FIXME: TextFilter objects should not be in the database!
        sym = filter.empty? ? :none : filter.to_sym
        FactoryGirl.create sym

        Blog.default.comment_text_filter = filter

        assert @comment.save
        assert @comment.errors.empty?

        assert @comment.html(:body) !~ /<script>/
      end
    end
  end

  describe 'change state' do
    it 'should becomes withdraw' do
      c = FactoryGirl.create(:comment)
      assert c.withdraw!
      assert ! c.published?
      assert c.spam?
      assert c.status_confirmed?
      c.reload
      assert ! c.published?
      assert c.spam?
      assert c.status_confirmed?
    end

    it 'should becomes not published in article if withdraw' do
      a = Article.new(:title => 'foo')
      assert a.save

      assert_equal 0, a.published_comments.size
      c = a.comments.build(:body => 'foo', :author => 'bob', :published => true, :published_at => Time.now)
      assert c.save
      assert c.published?
      c.reload
      a.reload

      assert_equal 1, a.published_comments.size
      c.withdraw!

      a = Article.new(:title => 'foo')
      assert_equal 0, a.published_comments.size
    end

    it 'should becomes confirmed if withdrawn' do
      unconfirmed = FactoryGirl.build_stubbed(:comment, :state => 'presumed_ham')
      unconfirmed.should_not be_status_confirmed
      unconfirmed.withdraw!
      unconfirmed.should be_status_confirmed
    end
  end

  it 'should have good default filter' do
    @blog.stub(:text_filter_object) { FactoryGirl.build_stubbed :textile }
    @blog.stub(:comment_text_filter) { FactoryGirl.build_stubbed :markdown }
    a = FactoryGirl.build_stubbed(:comment)
    assert_equal 'markdown', a.default_text_filter.name
  end

  describe 'with feedback moderation enabled' do
    before(:each) do
      @blog.stub(:sp_global) { false }
      @blog.stub(:default_moderate_comments) { true }
    end

    it 'should save comment as presumably spam' do
      comment = Comment.new do |c|
        c.body = "Test foo"
        c.author = 'Bob'
        c.article_id = FactoryGirl.create(:article).id
      end
      assert comment.save!

      assert ! comment.published?
      assert comment.spam?
      assert ! comment.status_confirmed?
    end

    it 'should save comment as confirmed ham' do
      henri = FactoryGirl.create(:user, :login => 'henri')
      comment = Comment.new do |c|
        c.body = "Test foo"
        c.author = 'Henri'
        c.article_id = FactoryGirl.create(:article).id
        c.user_id = henri.id
      end
      assert comment.save!

      assert comment.published?
      assert comment.ham?
      assert comment.status_confirmed?

    end
  end

end
