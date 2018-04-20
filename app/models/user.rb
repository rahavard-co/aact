class User < Admin::AdminBase
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  include ActiveModel::Validations
  after_create { create_db_account }
  after_save :grant_db_privs, :if => proc { |l| l.confirmed_at_changed? && l.confirmed_at_was.nil? }
  attr_accessor :current_password, :skip_password_validation
  devise :confirmable, :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable

  validates :current_password, presence: true, on: :update, unless: :skip_password_validation
  validates_confirmation_of :password
  validates :first_name, presence: true
  validates :last_name, presence: true
  validates_length_of :first_name, :maximum=>100
  validates_length_of :last_name, :maximum=>100
  validates :username, presence: true
  validates_uniqueness_of :username
  validates_length_of :username, :maximum=>64
  validates_format_of :username, :with => /\A[a-zA-Z0-9]+\z/, :message => "cannot contain special chars"
  validates_format_of :username, :with => /\A[a-zA-Z]/, :message => "must start with an alpha character"

  def create_db_account
    #self.skip_password_validation=true  # don't validate that user entered current password - they didn't have a chance to
    event=Admin::LoadEvent.create({
      :event_type=>'user-add',
      :status=>'complete',
      :description=>"user #{self.email}",
      :problems=>''})
    mgr=Util::UserDbManager.new({:load_event=>event})
    if mgr.can_create_user_account?(self)
      mgr.create_user_account(self)
    else
      self.errors.add('DB Account', 'could not be created for this user.')
      event.problems='Could not create this user.'
    end
  end

  def grant_db_privs
    event=Admin::LoadEvent.create({:event_type=>'grant-db-privs',:status=>'complete',:description=>"user #{self.email}",:problems=>''})
    Util::UserDbManager.new({:load_event=>event}).grant_db_privs(self.username)
  end

  def change_password(pwd)
    event=Admin::LoadEvent.create({:event_type=>'user-change-pwd',:status=>'complete',:description=>"user #{self.email}",:problems=>''})
    db_mgr=Util::UserDbManager.new({:load_event=>event})
    db_mgr.change_password(self, pwd)
  end

  def self.reset_password_by_token(params)
    original_token       = params[:reset_password_token]
    reset_password_token = Devise.token_generator.digest(self, :reset_password_token, original_token)
    resource=where('reset_password_token=?',reset_password_token).first
    if !resource.nil?
      resource.skip_password_validation=true
      resource.update_attributes({:password=>params[:password], :password_confirmation=>params[:password_confirmation]})
      resource.change_password(params[:password]) if resource.errors.empty?
    end
    resource
  end

  def update(params)
    params.delete(:password) if params[:password].blank?
    params.delete(:password_confirmation) if params[:password_confirmation].blank?
    update_attributes(params) if valid_password?(params['current_password'])
    event=Admin::LoadEvent.create({:event_type=>'user-update',:status=>'complete',:description=>"update user #{self.email}",:problems=>''})
    db_mgr=Util::UserDbManager.new({:load_event=>event})
    db_mgr.change_password(self, params[:password]) if params[:password]
    self
  end

  def remove
    begin
      Admin::RemovedUser.create(self.attributes.except('id', 'created_at', 'updated_at'))
      event=Admin::LoadEvent.create({:event_type=>'user-remove',:status=>'complete',:description=>"remove user #{self.email}",:problems=>''})
      db_mgr=Util::UserDbManager.new({:load_event=>event})
      db_mgr.pub_con.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '#{self.username}'")
      db_mgr.remove_user(self.username)
      destroy
    rescue => e
      puts e.message
    end
  end

  def full_name
    first_name + ' ' + last_name
  end

end
