Sanitize::Config::DANDELION = Sanitize::Config.merge(Sanitize::Config::RELAXED,
                                                     elements: Sanitize::Config::RELAXED[:elements] + %w[oembed],
                                                     attributes: Sanitize::Config::RELAXED[:attributes].merge(
                                                       {
                                                         :all => %w[class target],
                                                         'oembed' => ['url'],
                                                         'figure' => ['style'],
                                                         'span' => ['style'],
                                                         'h1' => ['style'],
                                                         'h2' => ['style'],
                                                         'h3' => ['style'],
                                                         'h4' => ['style'],
                                                         'h5' => ['style'],
                                                         'h6' => ['style'],
                                                         'p' => ['style']
                                                       }
                                                     ),
                                                     css: {
                                                       'properties' => %w[width text-align color background-color]
                                                     },
                                                     protocols: Sanitize::Config::RELAXED[:protocols].merge(
                                                       {
                                                         'oembed' => { 'url' => %w[http https] }
                                                       }
                                                     ),
                                                     remove_contents: true)
