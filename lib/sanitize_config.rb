Sanitize::Config::DANDELION = Sanitize::Config.merge(Sanitize::Config::RELAXED,
                                                     elements: Sanitize::Config::RELAXED[:elements] + ['oembed'],
                                                     attributes: Sanitize::Config::RELAXED[:attributes].merge(
                                                       {
                                                         :all => ['class'],
                                                         'oembed' => ['url'],
                                                         'figure' => ['style']
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
