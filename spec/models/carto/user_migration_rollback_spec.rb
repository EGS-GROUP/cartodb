require_relative '../../spec_helper_min'
require_relative '../../../app/models/carto/user_migration_import'
require_relative '../../../app/models/carto/user_migration_export'
require_relative '../../factories/organizations_contexts'
require_relative './helpers/user_migration_helper'
require './spec/support/factories/tables'
require './spec/support/factories/organizations'
require 'helpers/database_connection_helper'
require 'factories/carto_visualizations'

describe 'UserMigration' do
  include Carto::Factories::Visualizations
  include CartoDB::Factories
  include DatabaseConnectionHelper
  include UserMigrationHelper

  it_should_behave_like 'migrating metadata', true
  it_should_behave_like 'migrating metadata', false

  describe 'failing user imports should rollback' do
    before :each do
      @user = create_user_with_visualizations
      @carto_user = Carto::User.find(@user.id)
      @user_attributes = @carto_user.attributes

      @export = Carto::UserMigrationExport.create(
        user: @carto_user,
        export_metadata: true
      )
      @export.run_export
      destroy_user
    end

    after :each do
      @carto_user.destroy
    end

    it 'import failing in import_metadata should rollback' do
      allow_any_instance_of(Carto::RedisExportService).to receive(:restore_redis_from_hash_export).raises('Some exception')

      imp = import
      imp.run_import.should eq false
      imp.state.should eq 'failure'

      Carto::RedisExportService.any_instance.unstub(:restore_redis_from_hash_export)

      import.run_import.should eq true
    end

    it 'import failing in JobImport#run!' do
      allow_any_instance_of(CartoDB::DataMover::ImportJob).to receive(:grant_user_role).raises('Some exception')

      imp = import
      imp.run_import.should eq false
      imp.state.should eq 'failure'

      CartoDB::DataMover::ImportJob.any_instance.unstub(:grant_user_role)

      import.run_import.should eq true
    end

    it 'import failing creating user database and roles' do
      allow_any_instance_of(CartoDB::DataMover::ImportJob).to receive(:import_pgdump).raises('Some exception')

      imp = import
      imp.run_import.should eq false
      imp.state.should eq 'failure'

      CartoDB::DataMover::ImportJob.any_instance.unstub(:import_pgdump)

      import.run_import.should eq true
    end

    it 'import failing importing visualizations' do
      allow_any_instance_of(Carto::UserMetadataExportService).to receive(:import_search_tweets_from_directory).raises('Some exception')

      imp = import
      imp.run_import.should eq false
      imp.state.should eq 'failure'

      Carto::UserMetadataExportService.any_instance.unstub(:import_search_tweets_from_directory)

      import.run_import.should eq true
    end

    it 'fails importing an already existing user' do
      import.run_import.should eq true
      import.run_import.should eq false
    end

    it 'should continue with rollback if data import rollback fails' do
      allow_any_instance_of(CartoDB::DataMover::ImportJob).to receive(:grant_user_role).raises('Some exception')
      allow_any_instance_of(CartoDB::DataMover::ImportJob).to receive(:rollback_user).raises('Some exception')
      import.run_import.should eq false
      CartoDB::DataMover::ImportJob.any_instance.unstub(:grant_user_role)
      CartoDB::DataMover::ImportJob.any_instance.unstub(:rollback_user)
      import.run_import.should eq true
    end

    it 'should not remove user if already exists while importing' do
      import.run_import.should eq true
      import.run_import.should eq false
      Carto::User.exists?(@user.id).should eq true
    end

    it 'import record should exist if import_data fails and rollbacks' do
      allow_any_instance_of(Carto::UserMigrationImport).to receive(:do_import_data).raises('Some exception')

      imp = import
      imp.run_import.should eq false
      imp.state.should eq 'failure'

      Carto::UserMigrationImport.where(id: imp.id).should_not be_empty
      Carto::User.where(username: @carto_user.username).should be_empty

      Carto::UserMigrationImport.any_instance.unstub(:do_import_data)
    end

    it 'import failing importing visualizations does not remove assets' do
      allow_any_instance_of(Carto::UserMetadataExportService).to receive(:import_search_tweets_from_directory).raises('Some exception')
      Asset.any_instance.stubs(:use_s3?).returns(false)
      asset = Asset.create(asset_file: Rails.root + 'spec/support/data/cartofante_blue.png', user: @user)
      local_url = CGI.unescape(asset.public_url.gsub(/(http:)?\/\/#{CartoDB.account_host}/, ''))
      imp = import

      imp.run_import.should eq false
      imp.state.should eq 'failure'
      File.exists?((asset.public_uploaded_assets_path + local_url).gsub('/uploads/uploads/', '/uploads/')).should eq true
    end
  end

  describe 'failing organization organizations should rollback' do
    let!(:organization) { OrganizationFactory.new.create_organization_with_users }
    let(:owner) { organization.owner }
    let(:export) { Carto::UserMigrationExport.create(organization: organization, export_metadata: true) }
    let(:organization_import) do
      import = Carto::UserMigrationImport.create(
        exported_file: export.exported_file,
        database_host: organization.owner.attributes['database_host'],
        org_import: true,
        json_file: export.json_file,
        import_metadata: true,
        dry: false
      )
      import.stubs(:assert_organization_does_not_exist)
      import.stubs(:assert_user_does_not_exist)
      import
    end

    before do
      filepath = "#{Rails.root}/services/importer/spec/fixtures/visualization_export_with_two_tables.carto"
      data_import = DataImport.create(
        user_id: owner.id,
        data_source: filepath,
        updated_at: Time.now.utc,
        append: false,
        create_visualization: true
      )
      data_import.values[:data_source] = filepath

      data_import.run_import!
      data_import.success.should eq true

      export.run_export

      organization.destroy_cascade
    end

    it 'import failing in import_metadata should rollback' do
      allow_any_instance_of(Carto::RedisExportService).to receive(:restore_redis_from_hash_export).raises('Some exception')

      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'

      Carto::RedisExportService.any_instance.unstub(:restore_redis_from_hash_export)

      organization_import.run_import.should eq true
    end

    it 'import failing in JobImport#run!' do
      allow_any_instance_of(CartoDB::DataMover::ImportJob).to receive(:grant_user_role).raises('Some exception')

      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'

      CartoDB::DataMover::ImportJob.any_instance.unstub(:grant_user_role)

      organization_import.run_import.should eq true
    end

    it 'import failing creating user database and roles' do
      allow_any_instance_of(CartoDB::DataMover::ImportJob).to receive(:import_pgdump).raises('Some exception')

      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'

      CartoDB::DataMover::ImportJob.any_instance.unstub(:import_pgdump)

      organization_import.run_import.should eq true
    end

    it 'import failing importing visualizations' do
      allow_any_instance_of(Carto::UserMetadataExportService).to receive(:import_search_tweets_from_directory).raises('Some exception')

      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'

      Carto::UserMetadataExportService.any_instance.unstub(:import_search_tweets_from_directory)

      organization_import.run_import.should eq true
    end

    it 'import failing import visualizations with metadata_only option' do
      allow_any_instance_of(Carto::UserMetadataExportService).to receive(:import_search_tweets_from_directory).raises('Some exception')

      organization_import.import_data = false
      organization_import.save!
      organization_import.run_import.should eq false
      organization_import.state.should eq 'failure'
      organization_import.reload
    end

    it 'should fail if importing an already existing organization with metadata' do
      organization_import.run_import.should eq true
      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'
    end

    it 'import record should exist if import_data fails and rollbacks' do
      allow_any_instance_of(Carto::UserMigrationImport).to receive(:do_import_data).raises('Some exception')

      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'

      Carto::UserMigrationImport.where(id: organization_import.id).should_not be_empty
      Carto::Organization.where(id: organization.id).should be_empty

      Carto::UserMigrationImport.any_instance.unstub(:do_import_data)
    end

    it 'import failing importing visualizations does not remove assets' do
      Carto::StorageOptions::S3.stubs(:enabled?).returns(false)
      allow_any_instance_of(Carto::UserMetadataExportService).to receive(:import_search_tweets_from_directory).raises('Some exception')
      asset = Carto::Asset.for_organization(
        organization: organization,
        resource: File.open(Rails.root + 'spec/support/data/cartofante_blue.png')
      )

      organization_import.run_import.should eq false
      organization_import.reload.state.should eq 'failure'
      File.exists?(asset.storage_info[:identifier]).should eq true
    end
  end
end
