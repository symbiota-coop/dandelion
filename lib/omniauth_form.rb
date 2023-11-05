module OmniAuth
  class Form
    protected

    def css
      [
        %(<meta content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" name="viewport">),
        %(<link rel="stylesheet" href="/infinite_admin/plugins/bootstrap/bootstrap4/css/bootstrap.css">),
        %(<link rel="stylesheet" href="/stylesheets/app.css">),
        %(<link rel="stylesheet" href="/stylesheets/sign_in_with_ethereum.css">),
        %(<script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js"></script>),
        %(<script src="/javascripts/sign_in_with_ethereum.js"></script>)
      ].join("\n")
    end
  end
end
