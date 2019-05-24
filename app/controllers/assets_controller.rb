class AssetsController < ApplicationController
  include WopiUtil
  # include ActionView::Helpers
  include ActionView::Helpers::AssetTagHelper
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::UrlHelper
  include ActionView::Context
  include ApplicationHelper
  include InputSanitizeHelper
  include FileIconsHelper

  before_action :load_vars, except: :create_wopi_file
  before_action :check_read_permission, except: :file_present
  before_action :check_edit_permission, only: :edit

  def file_present
    respond_to do |format|
      format.json do
        if @asset.file.processing?
          render json: {}, status: 404
        else
          # Only if file is present,
          # check_read_permission
          check_read_permission

          # If check_read_permission already rendered error,
          # stop execution
          return if performed?

          # If check permission passes, return :ok
          render json: {
            'asset-id' => @asset.id,
            'image-tag-url' => @asset.file.get_url(:medium),
            'preview-url' => asset_file_preview_path(@asset),
            'filename' => truncate(escape_input(@asset.file_file_name),
                                   length: Constants::FILENAME_TRUNCATION_LENGTH),
            'download-url' => download_asset_path(@asset),
            'type' => asset_data_type(@asset)
          }, status: 200
        end
      end
    end
  end

  def step_file_present
    respond_to do |format|
      format.json do
        if @asset.file.processing?
          render json: { processing: true }
        elsif @asset.previewable? && (@asset.preview.processing? || !@asset.preview.present?)
          render json: { processing: true }
        else
          render json: {
            placeholder_html: render_to_string(
              partial: 'steps/attachments/placeholder.html.erb',
              locals: { asset: @asset, edit_page: false }
            ),
            processing: false
          }
        end
      end
    end
  end

  def file_preview
    response_json = {
      'id' => @asset.id,
      'type' => (@asset.is_image? ? 'image' : 'file'),

      'filename' => truncate(escape_input(@asset.file_file_name),
                             length: Constants::FILENAME_TRUNCATION_LENGTH),
      'download-url' => download_asset_path(@asset, timestamp: Time.now.to_i)
    }

    can_edit = if @assoc.class == Step
                 can_manage_protocol_in_module?(@protocol) || can_manage_protocol_in_repository?(@protocol)
               elsif @assoc.class == Result
                 can_manage_module?(@my_module)
               elsif @assoc.class == RepositoryCell
                 can_manage_repository_rows?(@repository.team)
               end

    if @asset.is_image?
      if ['image/jpeg', 'image/pjpeg'].include? @asset.file.content_type
        response_json['quality'] = @asset.file_image_quality || 90
      end
      response_json.merge!(
        'editable' =>  @asset.editable_image? && can_edit,
        'mime-type' => @asset.file.content_type,
        'processing' => @asset.file.processing?,
        'large-preview-url' => @asset.file.get_url(:large),
        'processing-img' => image_tag('medium/processing.gif')
      )
    elsif @asset.previewable? && !@asset.file.processing? &&
          (@asset.preview.processing? ||
          !@asset.preview.processing? && @asset.preview.exists?(:large))
      response_json.merge!(
        'editable' =>  false,
        'type' => 'image',
        'mime-type' => 'image/png',
        'processing' => @asset.preview.processing?,
        'large-preview-url' => @asset.preview.get_url(:large),
        'processing-img' => image_tag('medium/processing.gif')
      )
    else
      response_json.merge!(
        'processing'   => @asset.file.processing?,
        'preview-icon' => render_to_string(
          partial: 'shared/file_preview_icon.html.erb',
          locals: { asset: @asset }
        )
      )
    end

    if wopi_enabled? && wopi_file?(@asset)
      edit_supported, title = wopi_file_edit_button_status
      response_json['wopi-controls'] = render_to_string(
        partial: 'assets/wopi/file_wopi_controls.html.erb',
        locals: {
          asset: @asset,
          can_edit: can_edit,
          edit_supported: edit_supported,
          title: title
        }
      )
    end
    respond_to do |format|
      format.json do
        render json: response_json
      end
    end
  end

  # Check whether the wopi file can be edited and return appropriate response
  def wopi_file_edit_button_status
    file_ext = @asset.file_file_name.split('.').last
    if Constants::WOPI_EDITABLE_FORMATS.include?(file_ext)
      edit_supported = true
      title = ''
    else
      edit_supported = false
      title = if Constants::FILE_TEXT_FORMATS.include?(file_ext)
                I18n.t('assets.wopi_supported_text_formats_title')
              elsif Constants::FILE_TABLE_FORMATS.include?(file_ext)
                I18n.t('assets.wopi_supported_table_formats_title')
              else
                I18n.t('assets.wopi_supported_presentation_formats_title')
              end
    end
    return edit_supported, title
  end

  def download
    if !@asset.file_present
      render_404 and return
    elsif @asset.file.is_stored_on_s3?
      redirect_to @asset.file.presigned_url(download: true), status: 307
    else
      send_file @asset.file.path, filename: URI.unescape(@asset.file_file_name),
        type: @asset.file_content_type
    end
  end

  def edit
    action = @asset.file_file_size.zero? && !@asset.locked? ? 'editnew' : 'edit'
    @action_url = append_wd_params(@asset
                                  .get_action_url(current_user, action, false))
    @favicon_url = @asset.favicon_url('edit')
    tkn = current_user.get_wopi_token
    @token = tkn.token
    @ttl = (tkn.ttl * 1000).to_s
    create_wopi_file_activity(current_user, true)

    render layout: false
  end

  def view
    @action_url = append_wd_params(@asset
                                   .get_action_url(current_user, 'view', false))
    @favicon_url = @asset.favicon_url('view')
    tkn = current_user.get_wopi_token
    @token = tkn.token
    @ttl = (tkn.ttl * 1000).to_s

    render layout: false
  end

  def update_image
    @asset = Asset.find(params[:id])
    orig_file_size = @asset.file_file_size
    orig_file_name = @asset.file_file_name
    return render_403 unless can_read_team?(@asset.team)

    @asset.file = params[:image]
    @asset.file_file_name = orig_file_name
    @asset.save!
    # release previous image space
    @asset.team.release_space(orig_file_size)
    # Post process file here
    @asset.post_process_file(@asset.team)

    render_html = if @asset.step
                    asset_position = @asset.step.asset_position(@asset)
                    render_to_string(
                      partial: 'steps/attachments/item.html.erb',
                      locals: {
                        asset: @asset,
                        i: asset_position[:pos],
                        assets_count: asset_position[:count],
                        step: @asset.step
                      },
                      formats: :html
                    )
                  else
                    render_to_string(
                      partial: 'shared/asset_link',
                      locals: { asset: @asset, display_image_tag: true },
                      formats: :html
                    )
                  end

    respond_to do |format|
      format.json do
        render json: { html: render_html }
      end
    end
  end

  # POST: create_wopi_file_path
  def create_wopi_file
    # Presence validation
    params.require(%i(element_type element_id file_type))

    # File type validation
    render_403 && return unless %w(docx xlsx pptx).include?(params[:file_type])

    # Asset validation
    file = Paperclip.io_adapters.for(StringIO.new)
    file.original_filename = "#{params[:file_name]}.#{params[:file_type]}"
    file.content_type = wopi_content_type(params[:file_type])
    asset = Asset.new(file: file, created_by: current_user, file_present: true)

    unless asset.valid?(:wopi_file_creation)
      render json: {
        message: asset.errors
      }, status: 400 and return
    end

    # Create file depending on the type
    if params[:element_type] == 'Step'
      step = Step.find(params[:element_id].to_i)
      render_403 && return unless can_manage_protocol_in_module?(step.protocol) ||
                                  can_manage_protocol_in_repository?(step.protocol)
      step_asset = StepAsset.create!(step: step, asset: asset)

      edit_url = edit_asset_url(step_asset.asset_id)
    elsif params[:element_type] == 'Result'
      my_module = MyModule.find(params[:element_id].to_i)
      render_403 and return unless can_manage_module?(my_module)

      # First create result and then the asset
      result = Result.create(name: file.original_filename,
                             my_module: my_module,
                             user: current_user)
      result_asset = ResultAsset.create!(result: result, asset: asset)

      edit_url = edit_asset_url(result_asset.asset_id)
    else
      render_404 and return
    end

    # Return edit url
    render json: {
      success: true,
      edit_url: edit_url
    }, status: :ok
  end

  private

  def load_vars
    @asset = Asset.find_by_id(params[:id])
    return render_404 unless @asset

    @assoc ||= @asset.step
    @assoc ||= @asset.result
    @assoc ||= @asset.repository_cell

    if @assoc.class == Step
      @protocol = @asset.step.protocol
    elsif @assoc.class == Result
      @my_module = @assoc.my_module
    elsif @assoc.class == RepositoryCell
      @repository = @assoc.repository_column.repository
    end
  end

  def check_read_permission
    if @assoc.class == Step
      render_403 && return unless can_read_protocol_in_module?(@protocol) ||
                                  can_read_protocol_in_repository?(@protocol)
    elsif @assoc.class == Result
      render_403 and return unless can_read_experiment?(@my_module.experiment)
    elsif @assoc.class == RepositoryCell
      render_403 and return unless can_read_team?(@repository.team)
    end
  end

  def check_edit_permission
    if @assoc.class == Step
      render_403 && return unless can_manage_protocol_in_module?(@protocol) ||
                                  can_manage_protocol_in_repository?(@protocol)
    elsif @assoc.class == Result
      render_403 and return unless can_manage_module?(@my_module)
    elsif @assoc.class == RepositoryCell
      render_403 and return unless can_manage_repository_rows?(@repository.team)
    end
  end

  def append_wd_params(url)
    wd_params = ''
    params.keys.select { |i| i[/^wd.*/] }.each do |wd|
      next if wd == 'wdPreviousSession' || wd == 'wdPreviousCorrelation'
      wd_params += "&#{wd}=#{params[wd]}"
    end
    url + wd_params
  end

  def asset_params
    params.permit(
      :file
    )
  end

  def asset_data_type(asset)
    return 'wopi' if wopi_file?(asset)
    return 'image' if asset.is_image?

    'file'
  end
end
