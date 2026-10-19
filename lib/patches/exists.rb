# Extensions to provide Mongoid-like .exists? method for Array and ActiveModel::Errors

class Array
  # Works like Mongoid's .exists?
  def exists?(condition = nil, &)
    if condition.is_a?(Hash)
      # Example: arr.exists?(id: 5)
      any? { |el| condition.all? { |k, v| el.respond_to?(k) && el.public_send(k) == v } }
    elsif block_given?
      any?(&)
    else
      any?
    end
  end
end

class ActiveModel::Errors
  # Works like Mongoid's .exists?
  def exists?(attribute = nil)
    if attribute
      !self[attribute].empty?
    else
      !empty?
    end
  end
end
