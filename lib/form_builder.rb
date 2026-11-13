module Padrino
  module Helpers
    module FormBuilder
      # Each _block takes its own options, plus those every block shares: required and disabled, and the layout's tip,
      # hint, container_class, label_class and div_class (block_layout). input_block and field_block handle those
      class BootstrapFormBuilder < AbstractFormBuilder
        # Text

        # autocomplete takes an autofill token (name, email...), so browsers and password managers fill the field in
        def text_block(fieldname, placeholder: nil, autocomplete: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) do |attrs|
            text_field(fieldname, placeholder: placeholder, autocomplete: autocomplete, **attrs)
          end
        end

        # The admin's type for the id of a polymorphic association (auto_admin_fields), which dadmin/build calls as id_block
        alias id_block text_block

        def number_block(fieldname, placeholder: nil, min: nil, step: 'any', **block_options)
          input_block(fieldname, 'form-control', **block_options) { |attrs| number_field(fieldname, step: step, min: min, placeholder: placeholder, **attrs) }
        end

        def email_block(fieldname, placeholder: nil, autocomplete: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) do |attrs|
            email_field(fieldname, placeholder: placeholder, autocomplete: autocomplete, **attrs)
          end
        end

        def url_block(fieldname, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) { |attrs| url_field(fieldname, placeholder: placeholder, **attrs) }
        end

        # A field for setting a new password: new-password stops browsers filling in the saved one, which would change
        # nothing but re-hash it at full BCrypt cost (about 350 ms) on every save. dadmin/build calls it by name, for the
        # :password type admin_fields gives Account's password (models/concerns/core_extensions.rb)
        def password_block(fieldname, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) do |attrs|
            password_field(fieldname, autocomplete: 'new-password', placeholder: placeholder, **attrs)
          end
        end

        # Never sends a saved secret back to the browser: the field starts empty with the last 4 characters as a placeholder,
        # mass_assigning keeps the saved value when it's left blank, and Remove clears it. A saved secret is never required
        def secret_block(fieldname, required: false, disabled: false, hint: nil, container_class: 'mb-3', **layout)
          saved = object.send(fieldname)
          required = (required || model_required(fieldname)) && !saved
          content = password_field(fieldname,
                                   value: '', autocomplete: 'new-password', 'data-saved' => (true if saved),
                                   class: field_class(fieldname, 'form-control'), required: required, disabled: disabled,
                                   placeholder: ("••••#{saved.last(4)}" if saved))
          if saved
            content += %(
              <div class="form-check mt-1">
                <input class="form-check-input" type="checkbox" name="#{field_name(:clear_secrets)}[]" value="#{fieldname}" id="#{field_id(:clear_secrets, fieldname)}">
                <label class="form-check-label" for="#{field_id(:clear_secrets, fieldname)}">Remove</label>
              </div>
            ).html_safe
          end
          block_layout(fieldname, content, hint: hint || ('Leave blank to keep the saved value' if saved),
                                           container_class: container_class, required: required, **layout)
        end

        def shorturl_block(fieldname, stem: nil, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control shorturl', **block_options) do |attrs|
            copy_link = (%(<a href="javascript:;" data-bs-toggle="tooltip" title="Click to copy"><i class="bi bi-link-45deg"></i></a>) if object.persisted? && object.send(fieldname))
            %(<span class="stem">#{stem}</span>) + text_field(fieldname, placeholder: placeholder, **attrs) + copy_link.to_s
          end
        end

        def text_area_block(fieldname, rows: 5, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) { |attrs| text_area(fieldname, rows: rows, placeholder: placeholder, **attrs) }
        end

        def wysiwyg_block(fieldname, rows: 5, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control wysiwyg', **block_options) { |attrs| text_area(fieldname, rows: rows, placeholder: placeholder, **attrs) }
        end

        def color_block(fieldname, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control colorpicker', **block_options) { |attrs| text_field(fieldname, placeholder: placeholder, **attrs) }
        end

        # Selects and checkboxes

        def check_box_block(fieldname, container_class: 'form-check form-switch', label_class: 'form-check-label', **block_options)
          input_block(fieldname, 'form-check-input', container_class: container_class, label_class: label_class, **block_options) do |attrs|
            check_box(fieldname, **attrs)
          end
        end

        def select_block(fieldname, options: model.send(fieldname.to_s.pluralize), selected: object.send(fieldname), **block_options)
          input_block(fieldname, 'form-select', **block_options) { |attrs| select(fieldname, options: options, selected: selected, **attrs) }
        end

        def lookup_block(fieldname, lookup_url: nil, placeholder: nil, selected_link: nil, **block_options)
          value = object.send(fieldname)
          input_block(fieldname, 'form-select lookup', **block_options) do |attrs|
            select(fieldname, options: (value.present? ? [['', ''], ['', value]] : []), selected: value,
                              'data-lookup-url': lookup_url, placeholder: placeholder, **attrs) << " #{selected_link}".html_safe
          end
        end

        # Files and images
        # A new upload isn't marked required: only the field for replacing a saved file is

        def file_block(fieldname, required: false, disabled: false, container_class: 'mb-3', **layout)
          content = ''
          if !object.persisted? || !object.send(fieldname)
            content << file_field(fieldname, class: 'form-control')
          else
            required ||= model_required(fieldname)
            content << %(
              <div>
                <i class="bi bi-download"></i> <a target="_blank" href="#{ERB::Util.html_escape(object.send(fieldname).url)}">#{ERB::Util.html_escape(object.send(fieldname).name)}</a>
              </div>
              <div>
                #{file_field(fieldname, class: 'form-control', required: required, disabled: disabled)}
              </div>
              <label class="remove-file">
                Remove #{check_box(:"remove_#{fieldname}", class: 'form-check-input', disabled: disabled)}
              </label>
            )
          end
          block_layout(fieldname, content, container_class: container_class, required: required, **layout)
        end

        def image_block(fieldname, rotate: true, required: false, disabled: false, container_class: 'mb-3', **layout)
          content = ''
          if !object.persisted? || !object.send(fieldname)
            content << file_field(fieldname, class: 'form-control')
          else
            required ||= model_required(fieldname)
            url = object.send(fieldname).url
            # No url when the stored file is missing, as in development without the uploads
            if !error?(fieldname) && url
              src = URI::Parser.new.escape(url).gsub('(', '%28').gsub(')', '%29')
              content << %(
            <div style="margin-bottom: 1em">
              <a target="_blank" href="#{url}"><img style="max-height: 12.5rem" src="#{src}"></a>
            </div>
            )
            end
            content << %(
            <div>
              #{file_field(fieldname, class: 'form-control', required: required, disabled: disabled)}
            </div>
            )
            if object.respond_to?(:"rotate_#{fieldname}_by") && rotate
              content << %(
                <div class="input-group" style="width: 13em">
                  <span class="input-group-text">Rotate by</span>
                  #{select(:"rotate_#{fieldname}_by", options: ['', '90', '180', '270'], class: field_class(fieldname, 'form-select'), disabled: disabled)}
                  <span class="input-group-text">&deg;</span>
                </div>
              )
            end
            content << %(
              <label class="remove-image">
                Remove #{check_box(:"remove_#{fieldname}", class: 'form-check-input', disabled: disabled)}
              </label>
            )
          end
          block_layout(fieldname, content, container_class: container_class, required: required, **layout)
        end

        # Dates and times

        def date_block(fieldname, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control datepicker', **block_options) do |attrs|
            text_field(fieldname, placeholder: placeholder, value: object.send(fieldname)&.strftime('%Y-%m-%d'), **attrs)
          end
        end

        def datetime_block(fieldname, placeholder: nil, data: {}, **block_options)
          input_block(fieldname, 'form-control datetimepicker', **block_options) do |attrs|
            text_field(fieldname, placeholder: placeholder, value: object.send(fieldname)&.strftime('%Y-%m-%d %H:%M'), data: data, **attrs)
          end
        end

        # Money and percentages

        def currency_block(fieldname, money_symbol: '$', placeholder: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) do |attrs|
            %(<div class="input-group">
            <span class="input-group-text money-symbol">#{ERB::Util.html_escape(money_symbol)}</span>) +
              number_field(fieldname, step: 'any', placeholder: placeholder, **attrs) +
              %(</div>)
          end
        end

        def percentage_block(fieldname, placeholder: nil, **block_options)
          input_block(fieldname, 'form-control', **block_options) do |attrs|
            %(<div class="input-group">) +
              number_field(fieldname, step: 'any', placeholder: placeholder, **attrs) +
              %(
            <span class="input-group-text">%</span>
          </div>)
          end
        end

        # Buttons

        def submit_block(button_text: nil, destroy_url: nil, container_class: nil, div_class: nil, disabled: false)
          button_text ||= object.new_record? ? "Create #{model.to_s.underscore.humanize.downcase}" : "Update #{model.to_s.underscore.humanize.downcase}"
          disabled_attr = disabled ? ' disabled="disabled"' : ''
          disabled_class = disabled ? ' disabled' : ''
          content = %(
            <div class="#{container_class}">
              <div class="#{div_class}">
                <button class="btn btn-primary" type="submit"#{disabled_attr}>#{button_text}</button> )
          if !object.new_record? && destroy_url
            content << %(<a class="btn btn-danger#{disabled_class}" data-method="post" data-confirm="Are you sure you want to delete this #{model.to_s.underscore.humanize.downcase}?" href="#{destroy_url}"#{disabled_attr}>Delete</a>)
          end
          content << %(
              </div>
            </div>
          )
          content.html_safe
        end

        def block_layout(fieldname, content, tip: nil, hint: nil, container_class: nil, label_class: nil, div_class: nil, required: nil)
          tip = if tip
                  tip
                elsif object.new_record? && model.respond_to?(:new_tips) && model.new_tips[fieldname]
                  model.new_tips[fieldname]
                elsif !object.new_record? && model.respond_to?(:edit_tips) && model.edit_tips[fieldname]
                  model.edit_tips[fieldname]
                end
          tip_html = if tip
                       "
            <i id=\"tip-#{fieldname}\" class=\"bi bi-question-circle\" title=\"#{tip}\"></i>
            <script>
              $(function() {
                $('#tip-#{fieldname}').tooltip({placement: 'right'});
            });
            </script>
          "
                     end

          hint = if hint
                   hint
                 elsif object.new_record? && model.respond_to?(:new_hints) && model.new_hints[fieldname]
                   model.new_hints[fieldname]
                 elsif !object.new_record? && model.respond_to?(:edit_hints) && model.edit_hints[fieldname]
                   model.edit_hints[fieldname]
                 end
          hint_html = if hint
                        %(
                <small class="form-text">#{hint}</small>
          )
                      end

          error_html = if error?(fieldname)
                         %(
                <div class="invalid-feedback">#{error_message_on error_key(fieldname),
                                                                 prepend: model.human_attribute_name(fieldname)}</div>
          )
                       end

          block = if container_class && container_class.include?('form-check')
                    %(
            <div class="#{container_class}">
              #{content}
              <label for="#{model.to_s.underscore}_#{fieldname}" class="#{label_class}">
                #{model.human_attribute_name(fieldname)}#{'*' if required}
                #{tip_html}
                #{error_html}
                #{hint_html}
              </label>
              </div>
            )
                  else
                    %(
            <div class="#{container_class}">
              <label for="#{model.to_s.underscore}_#{fieldname}" class="#{label_class}">
                #{model.human_attribute_name(fieldname)}#{'*' if required}
                #{tip_html}
              </label>
              <div class="#{div_class}">
                #{content}
                #{error_html}
                #{hint_html}
              </div>
            </div>
            )
                  end
          block.html_safe
        end

        protected

        def model
          object.class
        end

        def model_required(fieldname)
          model._validators[fieldname] && model._validators[fieldname].any? do |validator|
            validator.class.to_s.include?('PresenceValidator') && validator.options.empty?
          end
        end

        # Lays out the field the block builds, which it's passed whether to require: if asked, or if the model's
        # validations require it
        def field_block(fieldname, required: false, container_class: 'mb-3', **layout)
          required ||= model_required(fieldname)
          block_layout(fieldname, yield(required), container_class: container_class, required: required, **layout)
        end

        # A field_block whose field takes the class, required and disabled attributes the block is passed
        def input_block(fieldname, classes, disabled: false, **block_options)
          field_block(fieldname, **block_options) do |required|
            yield(class: field_class(fieldname, classes), required: required, disabled: disabled)
          end
        end

        def field_class(fieldname, classes)
          [classes, ('is-invalid' if error?(fieldname))].compact.join(' ')
        end

        def error?(fieldname)
          error_message_on(error_key(fieldname)).present?
        end

        # Errors on an association's id are on the association
        def error_key(fieldname)
          fieldname.to_s.gsub('_id', '')
        end
      end
    end
  end
end
