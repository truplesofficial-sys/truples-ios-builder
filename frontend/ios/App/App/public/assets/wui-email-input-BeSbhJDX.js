import{C as e,_ as t,b as n,h as r,o as i,u as a,v as o}from"./wui-text-TVVEkjDw.js";import"./wui-input-text-DnH3Zf_4.js";var s=e`
  :host {
    position: relative;
    display: inline-block;
    width: 100%;
  }
`,c=function(e,t,n,r){var i=arguments.length,a=i<3?t:r===null?r=Object.getOwnPropertyDescriptor(t,n):r,o;if(typeof Reflect==`object`&&typeof Reflect.decorate==`function`)a=Reflect.decorate(e,t,n,r);else for(var s=e.length-1;s>=0;s--)(o=e[s])&&(a=(i<3?o(a):i>3?o(t,n,a):o(t,n))||a);return i>3&&a&&Object.defineProperty(t,n,a),a},l=class extends o{constructor(){super(...arguments),this.disabled=!1}render(){return n`
      <wui-input-text
        type="email"
        placeholder="Email"
        icon="mail"
        size="lg"
        .disabled=${this.disabled}
        .value=${this.value}
        data-testid="wui-email-input"
        tabIdx=${r(this.tabIdx)}
      ></wui-input-text>
      ${this.templateError()}
    `}templateError(){return this.errorMessage?n`<wui-text variant="sm-regular" color="error">${this.errorMessage}</wui-text>`:null}};l.styles=[a,s],c([t()],l.prototype,`errorMessage`,void 0),c([t({type:Boolean})],l.prototype,`disabled`,void 0),c([t()],l.prototype,`value`,void 0),c([t()],l.prototype,`tabIdx`,void 0),l=c([i(`wui-email-input`)],l);