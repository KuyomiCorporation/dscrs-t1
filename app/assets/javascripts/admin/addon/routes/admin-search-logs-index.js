import EmberObject from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminSearchLogsIndexRoute extends DiscourseRoute {
  queryParams = {
    period: { refreshModel: true },
    searchType: { refreshModel: true },
  };

  model(params) {
    this._params = params;
    return ajax("/admin/logs/search_logs.json", {
      data: { period: params.period, search_type: params.searchType },
    }).then((search_logs) => {
      return search_logs.map((sl) => EmberObject.create(sl));
    });
  }

  setupController(controller, model) {
    const params = this._params;
    controller.setProperties({
      model,
      period: params.period,
      searchType: params.searchType,
    });
  }
}
