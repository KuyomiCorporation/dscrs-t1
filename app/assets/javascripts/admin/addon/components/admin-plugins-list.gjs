import Component from "@glimmer/component";
import i18n from "discourse-common/helpers/i18n";
import AdminPluginsListItem from "./admin-plugins-list-item";

export default class AdminPluginsList extends Component {
  <template>
    <table class="admin-plugins-list grid">
      <thead>
        <tr>
          <th>{{i18n "admin.plugins.name"}}</th>
          <th>{{i18n "admin.plugins.version"}}</th>
          <th>{{i18n "admin.plugins.enabled"}}</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {{#each @plugins as |plugin|}}
          <AdminPluginsListItem @plugin={{plugin}} />
        {{/each}}
      </tbody>
    </table>
  </template>
}
