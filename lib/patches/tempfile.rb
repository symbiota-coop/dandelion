# The name of an uploaded file, which file_hashes_to_files! (app/helpers/param_helpers.rb) sets from the upload's
# params, and Dragonfly reads as the file's name
class Tempfile
  attr_accessor :original_filename
end
