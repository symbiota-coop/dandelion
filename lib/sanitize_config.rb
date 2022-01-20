Sanitize::Config::DANDELION = Sanitize::Config.merge(Sanitize::Config::RELAXED,
                                                     elements: Sanitize::Config::RELAXED[:elements] + ['oembed'],
                                                     attributes: Sanitize::Config::RELAXED[:attributes].merge(
                                                       {
                                                         :all => ['class'],
                                                         'oembed' => ['url'],
                                                         'figure' => ['style'],
                                                         'h1' => ['style'],
                                                         'h2' => ['style'],
                                                         'h3' => ['style'],
                                                         'h4' => ['style'],
                                                         'h5' => ['style'],
                                                         'h6' => ['style']
                                                       }
                                                     ),
                                                     css: {
                                                       'properties' => %w[width text-align]
                                                     },
                                                     protocols: Sanitize::Config::RELAXED[:protocols].merge(
                                                       {
                                                         'oembed' => { 'url' => %w[http https] }
                                                       }
                                                     ),
                                                     remove_contents: true)
