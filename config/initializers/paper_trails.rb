# PaperTrail.track_associations is not set by default. As of PaperTrail 5, it defaults to false.
PaperTrail.config.track_associations = true

# Ensure PaperTrail can load YAML-formatted object history
::ActiveRecord.yaml_column_permitted_classes = [
  ::ActiveRecord::Type::Time::Value,
  ::ActiveSupport::TimeWithZone,
  ::ActiveSupport::TimeZone,
  ::BigDecimal,
  ::Date,
  ::Symbol,
  ::Time
]
