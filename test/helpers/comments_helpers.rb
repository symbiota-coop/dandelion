# Helpers the comment test files (test/messages) share
module CommentsHelpers
  # A thread in @gathering's General team, opened by @member with @comment
  def team_thread
    create_gathering
    @team = @gathering.teams.find_by(name: 'General')
    @member = create_member
    @post = @team.posts.create!(account: @member, subject: 'Rota')
    @comment = @post.comments.create!(account: @member, body: 'Secret plans')
  end
end
