class Mailboxer::Receipt < ActiveRecord::Base
  self.table_name = :mailboxer_receipts
  attr_accessible :trashed, :is_read, :deleted, :is_delivered if Mailboxer.protected_attributes?

  belongs_to :notification, :class_name => "Mailboxer::Notification"
  belongs_to :receiver, :polymorphic => :true, :required => false
  belongs_to :message, :class_name => "Mailboxer::Message", :foreign_key => "notification_id", :required => false

  validates_presence_of :receiver

  #
  # Callbacks
  #
  after_create    :after_create_callback

  scope :recipient, lambda { |recipient|
    where(:receiver_id => recipient.id,:receiver_type => recipient.class.base_class.to_s)
  }
  #Notifications Scope checks type to be nil, not Notification because of STI behaviour
  #with the primary class (no type is saved)
  scope :notifications_receipts, lambda { joins(:notification).where('mailboxer_notifications.type' => nil) }
  scope :messages_receipts, lambda { joins(:notification).where('mailboxer_notifications.type' => Mailboxer::Message.to_s) }
  scope :notification, lambda { |notification|
    where(:notification_id => notification.id)
  }
  scope :conversation, lambda { |conversation|
    joins(:message).where('mailboxer_notifications.conversation_id' => conversation.id)
  }
  scope :sentbox, lambda { where(:mailbox_type => "sentbox") }
  scope :inbox, lambda { where(:mailbox_type => "inbox") }
  scope :trash, lambda { where(:trashed => true, :deleted => false) }
  scope :not_trash, lambda { where(:trashed => false) }
  scope :deleted, lambda { where(:deleted => true) }
  scope :not_deleted, lambda { where(:deleted => false) }
  scope :is_read, lambda { where(:is_read => true) }
  scope :is_unread, lambda { where(:is_read => false) }
  scope :is_delivered, lambda { where(:is_delivered => true) }

  class << self
    #Marks all the receipts from the relation as read
    def mark_as_read(options={})
      update_receipts({:is_read => true}, options)
    end

    #Marks all the receipts from the relation as unread
    def mark_as_unread(options={})
      update_receipts({:is_read => false}, options)
    end

    #Marks all the receipts from the relation as trashed
    def move_to_trash(options={})
      update_receipts({:trashed => true}, options)
    end

    #Marks all the receipts from the relation as not trashed
    def untrash(options={})
      update_receipts({:trashed => false}, options)
    end

    #Marks the receipt as deleted
    def mark_as_deleted(options={})
      update_receipts({:deleted => true}, options)
    end

    #Marks the receipt as not deleted
    def mark_as_not_deleted(options={})
      update_receipts({:deleted => false}, options)
    end

    #Moves all the receipts from the relation to inbox
    def move_to_inbox(options={})
      update_receipts({:mailbox_type => :inbox, :trashed => false}, options)
    end

    #Moves all the receipts from the relation to sentbox
    def move_to_sentbox(options={})
      update_receipts({:mailbox_type => :sentbox, :trashed => false}, options)
    end

    def update_receipts(updates, options={})
      ids = where(options).map { |rcp| rcp.id }
      unless ids.empty?
        sql = ids.map { "#{table_name}.id = ? " }.join(' OR ')
        conditions = [sql].concat(ids)
        Mailboxer::Receipt.where(conditions).update_all(updates)
      end
    end
  end


  #Marks the receipt as deleted
  def mark_as_deleted
    self.update_attributes(deleted: true)
    # удаляем сообщение у получателя если он его ещё не прочёл
    message_receiver = self.receiver.is_a?(User) ? self.receiver : self.receiver.user
    if message_receiver_receipt = self.message.receipts_for(message_receiver).first
      if not message_receiver_receipt.is_read?
        message_receiver_receipt.mark_as_deleted
        data = { message_id: message_receiver_receipt.id, conversation_id: self.conversation.id }
        Websocket.publish "user/#{message_receiver.id}", data, 'messages/destroy'
      end
    end
  end

  #Marks the receipt as not deleted
  def mark_as_not_deleted
    self.update_attributes(deleted: false)
  end

  #Marks the receipt as read
  def mark_as_read
    # отмечаем сообщение как прочитанное для себя
    self.update_attributes(is_read: true)
    # отмечаем сообщение как прочитанное для отправителя
    sender_message_receipt = self.message.receipts_for(self.message.sender).first
    sender_message_receipt.update_attributes(is_read: true) if not self.is_for_sender?
    # отправить сообщение в websocket
    message_receiver = self.message.sender.is_a?(User) ? self.message.sender : self.message.sender.user
    data = { message_id: sender_message.id, conversation_id: self.conversation.id, is_read: true }
    Websocket.publish "user/#{message_receiver.id}", data, 'messages/read'
  end

  #Marks the receipt as unread
  def mark_as_unread
    self.update_attributes(is_read: false)
  end

  #Marks the receipt as trashed
  def move_to_trash
    update_attributes(:trashed => true)
  end

  #Marks the receipt as not trashed
  def untrash
    update_attributes(:trashed => false)
  end

  #Moves the receipt to inbox
  def move_to_inbox
    update_attributes(:mailbox_type => :inbox, :trashed => false)
  end

  #Moves the receipt to sentbox
  def move_to_sentbox
    update_attributes(:mailbox_type => :sentbox, :trashed => false)
  end

  #Returns the conversation associated to the receipt if the notification is a Message
  def conversation
    message.conversation if message.is_a? Mailboxer::Message
  end

  #Returns if the participant have read the Notification
  def is_unread?
    !is_read
  end

  #Returns if the participant have trashed the Notification
  def is_trashed?
    trashed
  end

  def is_for_sender?
    self.message.sender == self.receiver
  end

protected
  if Mailboxer.search_enabled
    searchable do
      text :subject, :boost => 5 do
        message.subject if message
      end
      text :body do
        message.body if message
      end
      integer :receiver_id
    end
  end

private
  def after_create_callback
    self.update_columns(is_read: false)
    message_receiver = self.receiver.is_a?(User) ? self.receiver : self.receiver.user
    # отправить сообщение в websocket
    Websocket.publish "user/#{message_receiver.id}", CachedSerializer.render(self, MessageSerializer), 'messages/new'
    # отправить уведомление на email если с момента последнего сообщения получателя прошло более 4-х часов
    send_email_notification = true
    if self.conversation.messages.where(sender: message_receiver).last
      send_email_notification = self.conversation.messages.where(sender: message_receiver).last.created_at < Time.now - 4.hours
    end
    send_email_notification = false if message_receiver.online

    Resque.enqueue(SendNotificationJob, 'new_message', {
      user_id: message_receiver, user_type: message_receiver.class.name, sender_name: self.message.sender.name,
      time: self.message.created_at.strftime("%d %B %Y %H:%M"), message: self.message.body,
      conversation_id: self.conversation.id
    }) if send_email_notification
  end

end
