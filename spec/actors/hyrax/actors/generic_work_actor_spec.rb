require 'spec_helper'
require 'redlock'

describe Hyrax::Actors::GenericWorkActor do
  include ActionDispatch::TestProcess

  let(:user) { create(:user) }
  let(:file_path) { File.join(fixture_path, 'image.png') }
  let(:file) { Rack::Test::UploadedFile.new(file_path, 'image/png', false) }
  # stub out redis connection
  let(:redlock_client_stub) do
    client = double('redlock client')
    allow(client).to receive(:lock).and_yield(true)
    allow(Redlock::Client).to receive(:new).and_return(client)
    client
  end

  subject do
    Hyrax::CurationConcern.actor(curation_concern, ::Ability.new(user))
  end

  let(:admin_set) { create(:admin_set, with_permission_template: { with_active_workflow: true }) }

  describe '#create' do
    let(:curation_concern) { GenericWork.new }
    let(:xmas) { DateTime.parse('2014-12-25 11:30').iso8601 }

    context 'failure' do
      before do
        allow(subject).to receive(:attach_files).and_return(true)
      end

      it 'returns false' do
        expect(curation_concern).to receive(:save).and_return(false)
        expect(subject.create({})).to be false
      end
    end

    context 'success' do
      before do
        redlock_client_stub
      end

      it "invokes the after_create_concern callback" do
        allow(CharacterizeJob).to receive(:perform_later).and_return(true)
        expect(Hyrax.config.callback).to receive(:run)
          .with(:after_create_concern, curation_concern, user)
        subject.create(title: ['Foo Bar'], admin_set_id: admin_set.id)
      end
    end

    context 'valid attributes' do
      let(:visibility) { Hydra::AccessControls::AccessRight::VISIBILITY_TEXT_VALUE_AUTHENTICATED }
      before do
        redlock_client_stub
      end

      context 'with embargo' do
        context "with attached files" do
          let(:date) { Time.zone.today + 2 }
          let(:attributes) do
            { title: ['New embargo'], visibility: Hydra::AccessControls::AccessRight::VISIBILITY_TEXT_VALUE_EMBARGO,
              visibility_during_embargo: 'authenticated', embargo_release_date: date.to_s,
              visibility_after_embargo: 'open', visibility_during_lease: 'open',
              lease_expiration_date: '2014-06-12', visibility_after_lease: 'restricted',
              admin_set_id: admin_set.id,
              files: [
                file
              ],
              license: ['http://creativecommons.org/licenses/by/3.0/us/'] }
          end

          it "applies embargo to attached files" do
            allow(CharacterizeJob).to receive(:perform_later).and_return(true)
            subject.create(attributes)
            file = curation_concern.file_sets.first
            expect(file).to be_persisted
            expect(file.visibility_during_embargo).to eq 'authenticated'
            expect(file.visibility_after_embargo).to eq 'open'
            expect(file.visibility).to eq 'authenticated'
          end
        end
      end

      context 'with in_work_ids' do
        let(:parent) { create(:generic_work, user: user) }
        let(:attributes) do
          FactoryGirl.attributes_for(:generic_work, visibility: visibility, admin_set_id: admin_set.id).merge(
            in_works_ids: [parent.id]
          )
        end
        it "attaches the parent" do
          allow_any_instance_of(Hyrax::Actors::AddToWorkActor).to receive(:can_edit_both_works?).and_return(true)
          expect(subject.create(attributes)).to be true
          expect(curation_concern.in_works).to eq [parent]
        end
        it "does not attach the parent" do
          allow_any_instance_of(Hyrax::Actors::AddToWorkActor).to receive(:can_edit_both_works?).and_return(false)
          expect(subject.create(attributes)).to be false
          expect(curation_concern.in_works).to eq []
        end
      end

      context 'with a file' do
        let(:attributes) do
          FactoryGirl.attributes_for(:generic_work, admin_set_id: admin_set.id, visibility: visibility).tap do |a|
            a[:files] = file
          end
        end

        context 'authenticated visibility' do
          let(:file_actor) { double }
          before do
            allow(Hyrax::TimeService).to receive(:time_in_utc) { xmas }
            allow(Hyrax::Actors::FileActor).to receive(:new).and_return(file_actor)
            allow(Hyrax.config.callback).to receive(:run).with(:after_create_concern, GenericWork, user)
          end

          it 'stamps each file with the access rights and runs callbacks' do
            expect(Hyrax.config.callback).to receive(:run).with(:after_create_fileset, FileSet, user)

            expect(file_actor).to receive(:ingest_file).and_return(true)
            expect(subject.create(attributes)).to be true
            expect(curation_concern).to be_persisted
            expect(curation_concern.date_uploaded).to eq xmas
            expect(curation_concern.date_modified).to eq xmas
            expect(curation_concern.depositor).to eq user.user_key
            expect(curation_concern.representative).not_to be_nil
            expect(curation_concern.file_sets.size).to eq 1
            expect(curation_concern).to be_authenticated_only_access
            # Sanity test to make sure the file_set has same permission as parent.
            file_set = curation_concern.file_sets.first
            expect(file_set).to be_authenticated_only_access
          end
        end
      end

      context 'with multiple files' do
        let(:file_actor) { double }
        let(:attributes) do
          FactoryGirl.attributes_for(:generic_work, admin_set_id: admin_set.id, visibility: visibility).tap do |a|
            a[:files] = [file, file]
          end
        end

        context 'authenticated visibility' do
          before do
            allow(Hyrax::TimeService).to receive(:time_in_utc) { xmas }
            allow(Hyrax::Actors::FileActor).to receive(:new).and_return(file_actor)
          end

          it 'stamps each file with the access rights' do
            expect(file_actor).to receive(:ingest_file).and_return(true).twice

            expect(subject.create(attributes)).to be true
            expect(curation_concern).to be_persisted
            expect(curation_concern.date_uploaded).to eq xmas
            expect(curation_concern.date_modified).to eq xmas
            expect(curation_concern.depositor).to eq user.user_key

            expect(curation_concern.file_sets.size).to eq 2
            # Sanity test to make sure the file we uploaded is stored and has same permission as parent.

            expect(curation_concern).to be_authenticated_only_access
          end
        end
      end

      context 'with a present and a blank title' do
        let(:attributes) do
          FactoryGirl.attributes_for(:generic_work, admin_set_id: admin_set.id, title: ['this is present', ''])
        end

        it 'stamps each link with the access rights' do
          expect(subject.create(attributes)).to be true
          expect(curation_concern).to be_persisted
          expect(curation_concern.title).to eq ['this is present']
        end
      end
    end
  end

  describe '#update' do
    let(:curation_concern) { create(:generic_work, user: user, admin_set_id: admin_set.id) }

    context 'failure' do
      let(:attributes) { {} }

      it 'returns false' do
        expect(curation_concern).to receive(:save).and_return(false)
        expect(subject.update(attributes)).to be false
      end
    end

    context 'success' do
      it "invokes the after_update_metadata callback" do
        expect(Hyrax.config.callback).to receive(:run)
          .with(:after_update_metadata, curation_concern, user)
        subject.update(title: ['Other Title'])
      end
    end

    context 'with in_works_ids' do
      let(:parent) { create(:generic_work, user: user) }
      let(:old_parent) { create(:generic_work, user: user) }
      let(:attributes) do
        FactoryGirl.attributes_for(:generic_work).merge(
          in_works_ids: [parent.id]
        )
      end
      before do
        old_parent.ordered_members << curation_concern
        old_parent.save!
      end
      it "attaches the parent" do
        expect(subject.update(attributes)).to be true
        expect(curation_concern.in_works).to eq [parent]
        expect(old_parent.reload.members).to eq []
      end
    end
    context 'without in_works_ids' do
      let(:old_parent) { FactoryGirl.create(:generic_work) }
      let(:attributes) do
        FactoryGirl.attributes_for(:generic_work).merge(
          in_works_ids: []
        )
      end
      before do
        curation_concern.apply_depositor_metadata(user.user_key)
        curation_concern.save!
        old_parent.ordered_members << curation_concern
        old_parent.save!
      end
      it "removes the old parent" do
        allow(curation_concern).to receive(:depositor).and_return(old_parent.depositor)
        expect(subject.update(attributes)).to be true
        expect(curation_concern.in_works).to eq []
        expect(old_parent.reload.members).to eq []
      end
    end
    context 'with nil in_works_ids' do
      let(:parent) { FactoryGirl.create(:generic_work) }
      let(:attributes) do
        FactoryGirl.attributes_for(:generic_work).merge(
          in_works_ids: nil
        )
      end
      before do
        curation_concern.apply_depositor_metadata(user.user_key)
        curation_concern.save!
        parent.ordered_members << curation_concern
        parent.save!
      end
      it "does nothing" do
        expect(subject.update(attributes)).to be true
        expect(curation_concern.in_works).to eq [parent]
      end
    end
    context 'adding to collections' do
      let!(:collection1) { create(:collection, user: user) }
      let!(:collection2) { create(:collection, user: user) }
      let(:attributes) do
        FactoryGirl.attributes_for(:generic_work, member_of_collection_ids: [collection2.id])
      end
      before do
        curation_concern.apply_depositor_metadata(user.user_key)
        curation_concern.member_of_collections = [collection1]
        curation_concern.save!
      end

      it 'remove from the old collection and adds to the new collection' do
        curation_concern.reload
        expect(curation_concern.member_of_collection_ids).to eq [collection1.id]
        # before running actor.update, the work is in collection1

        expect(subject.update(attributes)).to be true

        curation_concern.reload
        expect(curation_concern.identifier).to be_blank
        expect(curation_concern).to be_persisted
        # after running actor.update, the work is in collection2 and no longer in collection1
        expect(curation_concern.member_of_collections).to eq [collection2]
      end
    end

    context 'with multiple file sets' do
      let(:file_set1) { create(:file_set) }
      let(:file_set2) { create(:file_set) }
      let(:curation_concern) { create(:generic_work, user: user, ordered_members: [file_set1, file_set2], admin_set_id: admin_set.id) }
      let(:attributes) do
        FactoryGirl.attributes_for(:generic_work, ordered_member_ids: [file_set2.id, file_set1.id])
      end
      it 'updates the order of file sets' do
        expect(curation_concern.ordered_members.to_a).to eq [file_set1, file_set2]
        expect(subject.update(attributes)).to be true

        curation_concern.reload
        expect(curation_concern.ordered_members.to_a).to eq [file_set2, file_set1]
      end
      ## Is this something we want to support?
      context "when told to stop ordering a file set" do
        let(:attributes) do
          FactoryGirl.attributes_for(:generic_work, ordered_member_ids: [file_set2.id])
        end
        it "works" do
          expect(curation_concern.ordered_members.to_a).to eq [file_set1, file_set2]

          expect(subject.update(attributes)).to be true

          curation_concern.reload
          expect(curation_concern.ordered_members.to_a).to eq [file_set2]
        end
      end
    end
  end
end
