module Hyrax
  class Admin::CollectionTypesController < ApplicationController
    before_action do
      authorize! :manage, :collection_types
    end
    before_action :set_collection_type, only: [:edit, :update, :destroy]

    layout 'dashboard'
    class_attribute :form_class
    self.form_class = Hyrax::Forms::Admin::CollectionTypeForm

    def index
      add_common_breadcrumbs
    end

    def new
      setup_form
      add_common_breadcrumbs
      add_breadcrumb t(:'hyrax.admin.collection_types.new.header'), hyrax.new_admin_collection_type_path
    end

    def create
      @collection_type = Hyrax::CollectionType.new(collection_type_params)
      if @collection_type.save
        redirect_to hyrax.edit_admin_collection_type_path(@collection_type), notice: t(:'hyrax.admin.collection_types.create.notification', name: @collection_type.title)
      else
        setup_form
        add_common_breadcrumbs
        add_breadcrumb t(:'hyrax.admin.collection_types.new.header'), hyrax.new_admin_collection_type_path
        render :new
      end
    end

    def edit
      setup_form
      add_common_breadcrumbs
      add_breadcrumb t(:'hyrax.admin.collection_types.edit.header'), hyrax.edit_admin_collection_type_path
    end

    def update
      if @collection_type.update(collection_type_params)
        redirect_to hyrax.edit_admin_collection_type_path(@collection_type), notice: t(:'hyrax.admin.collection_types.update.notification', name: @collection_type.title)
      else
        setup_form
        add_common_breadcrumbs
        add_breadcrumb t(:'hyrax.admin.collection_types.edit.header'), hyrax.edit_admin_collection_type_path
        render :edit
      end
    end

    def destroy
      if @collection_type.destroy
        redirect_to hyrax.admin_collection_types_path, notice: t(:'hyrax.admin.collection_types.delete.notification', name: @collection_type.title)
      else
        redirect_to hyrax.admin_collection_types_path, alert: @collection_type.errors.full_messages.to_sentence
      end
    end

    private

      def add_common_breadcrumbs
        add_breadcrumb t(:'hyrax.controls.home'), root_path
        add_breadcrumb t(:'hyrax.dashboard.breadcrumbs.admin'), hyrax.dashboard_path
        add_breadcrumb t(:'hyrax.admin.sidebar.configuration'), '#'
        add_breadcrumb t(:'hyrax.admin.collection_types.index.breadcrumb'), hyrax.admin_collection_types_path
      end

      # initialize the form object
      def form
        @form ||= form_class.new
      end
      alias setup_form form

      def set_collection_type
        @collection_type = Hyrax::CollectionType.find(params[:id])
      end

      def collection_type_params
        params.require(:collection_type).permit(:title, :machine_id, :nestable, :discoverable, :sharable, :allow_multiple_membership, :require_membership, :assigns_workflow, :assigns_visibility)
      end
  end
end
