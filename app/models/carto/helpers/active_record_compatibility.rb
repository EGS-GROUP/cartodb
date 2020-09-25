module Carto::ActiveRecordCompatibility
  # This module is meant to contain methods present in ActiveRecord
  # models but not in Sequel, in order to provide a light
  # compatibility layer

  def new_record?
    new?
  end

  def save!
    save(raise_on_failure: true)
  end

  def attributes
    values.with_indifferent_access
  end
end
