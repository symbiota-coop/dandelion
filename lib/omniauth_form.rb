module OmniAuth
  class Form
    protected

    def css
      [
        %(<link rel="stylesheet" href="/infinite_admin/plugins/bootstrap/bootstrap4/css/bootstrap.css">),
        %(<link rel="stylesheet" href="/stylesheets/app.css">),
        %(<link rel="stylesheet" href="/stylesheets/sign_in_with_ethereum.css">),
        %(<script src="/infinite_admin/plugins/jquery/jquery-3.2.1.min.js"></script>),
        %(<script src="/javascripts/sign_in_with_ethereum.js"></script>)
      ].join("\n")
    end
  end
end
