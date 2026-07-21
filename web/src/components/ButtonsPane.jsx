import { isNative } from '../bridge'
import ProfileEditModal from './ProfileEditModal'

// In-page profile list + footer. The actual button/swipe mapping rows live
// inside ProfileEditModal, opened via 编辑 or 新建配置… (matching the design:
// profile picker on the page, mapping editor in a modal).
function NativeButtonsPane({ dev, profile, profiles, mappings,
  onSelectProfile, onSetButton, onSetSwipe, onSetScrollSpeed, onResetMappings,
  onSetCustomText, onSetCustomKey,
  onCreateProfile, onRenameProfile, onDeleteProfile, onResetProfile,
  onEditProfile }) {
  const gen = dev.art === 'gen1' ? '1 代' : '2/3 代'

  if (!mappings) {
    return <div className="pane"><p className="group-label">映射配置 · {dev.name}（{gen}）</p></div>
  }

  return (
    <div className="pane">
      <p className="group-label">映射配置 · {dev.name}（{gen}）</p>
      <div className="group">
        <div className="prof-list">
          {profiles.map((p) => (
            <div className="prof-row" key={p.id}>
              <span className="prof-name">
                {p.name}
              </span>
              <span className="prof-row-actions">
                <button
                  className="prof-icon-btn"
                  type="button"
                  onClick={() => onEditProfile(p.id)}
                >{p.id === 'default' ? '查看' : '编辑'}</button>
                {p.id !== 'default' && (
                <button
                  className="prof-icon-btn"
                  type="button"
                  onClick={() => onResetProfile(p.id)}
                >重置</button>
                )}
                <button
                  className="prof-icon-btn danger"
                  type="button"
                  onClick={() => onDeleteProfile(p.id)}
                  disabled={p.builtin}
                  title={p.builtin ? '内置配置不可删除' : ''}
                >删除</button>
              </span>
            </div>
          ))}
        </div>
        <div className="map-foot">
          <button className="abtn abtn-ghost" onClick={onResetMappings}>恢复默认映射</button>
          <button className="abtn" onClick={onCreateProfile}>新建配置…</button>
        </div>
        <p className="map-note">点击「编辑」在弹窗中调整按键与触控板映射。</p>
      </div>
    </div>
  )
}

// Browser-mode fallback (no native bridge). Kept thin — the design is built
// around real profile data from Swift, so the no-bridge variant is for dev
// preview only.
export default function ButtonsPane({
  dev, profile, profiles,
  onSelectProfile, onWriteRow, onReset,
  onCreate, onRename, onDelete, showToast,
  onCreateProfile, onRenameProfile, onDeleteProfile,
  mappings, onSetButton, onSetSwipe, onSetScrollSpeed, onResetMappings,
  onSetCustomText, onSetCustomKey,
  onResetProfile, onEditProfile, onCloseModal, editingProfileId,
  onSetTrackpadMode, editMappings,
}) {
  if (isNative) {
    return (
      <>
        <NativeButtonsPane
          dev={dev}
          mappings={mappings}
          profile={profile}
          profiles={profiles}
          onSelectProfile={onSelectProfile}
          onSetButton={onSetButton}
          onSetSwipe={onSetSwipe}
          onSetScrollSpeed={onSetScrollSpeed}
          onResetMappings={onResetMappings}
          onSetCustomText={onSetCustomText}
          onSetCustomKey={onSetCustomKey}
          onCreateProfile={onCreateProfile}
          onRenameProfile={onRenameProfile}
          onDeleteProfile={onDeleteProfile}
          onResetProfile={onResetProfile}
          onEditProfile={onEditProfile}
        />
        {editingProfileId && (
          <ProfileEditModal
            dev={dev}
            profile={profiles.find(p => p.id === editingProfileId)}
            mappings={editMappings || mappings}
            onSetButton={onSetButton}
            onSetSwipe={onSetSwipe}
            onSetScrollSpeed={onSetScrollSpeed}
            onSetCustomText={onSetCustomText}
            onSetCustomKey={onSetCustomKey}
            onRenameProfile={onRenameProfile}
            onSetTrackpadMode={onSetTrackpadMode}
            onClose={onCloseModal}
          />
        )}
      </>
    )
  }
  return <div className="pane" />
}