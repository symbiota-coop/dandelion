Dandelion::App.helpers do
  # A GET can be sent with the viewer's session by another site's link or an <img> on any page, so a GET route whose
  # links people have (an email's unsubscribe link, an old bookmark) only asks, and the button POSTs to the same path,
  # where the route does it. The query is dropped: a link token in it has signed them in already
  def confirm_by_post(question, button:, cancel_path: '/')
    @question = question
    @button = button
    @cancel_path = cancel_path
    erb :confirm_by_post
  end
end
